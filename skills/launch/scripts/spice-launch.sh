#!/bin/bash
set -e

# Take a scenario's spicepod from a local directory to a production-ready Spice.ai
# Cloud project: create (or fork) the project, wire its secrets, deploy, prove the
# new version serves data, models, and MCP, add monitors and run a fire drill, and
# write the hand-off docs. Uses the installed `spice` CLI for project, deploy,
# status, and log operations, and the Cloud Management API for the rest.
#
# Usage:
#   spice-launch.sh login     [DIR] [--wait] [--timeout SECS] [--force] [--store keychain|env]
#   spice-launch.sh preflight [DIR] [--project ORG/NAME]
#   spice-launch.sh local     [DIR] [--timeout SECS]
#   spice-launch.sh create    [DIR] --project ORG/NAME [--region us-east-1|us-west-2] [--base ORG/BASE]
#                             [--profile demo|poc|production] [--replicas N] [--channel stable]
#   spice-launch.sh secrets   [DIR] [--set NAME]...
#   spice-launch.sh deploy    [DIR] [--timeout SECS] [--init-timeout SECS]
#   spice-launch.sh verify    [DIR] [--sql SQL]... [--ask QUESTION] [--search TEXT] [--nsql QUESTION]
#                             [--samples N] [--no-model] [--no-mcp]
#   spice-launch.sh monitors  [DIR] [--profile P] [--email ADDR]... [--slack CHANNEL_ID] [--webhook URL]
#                             [--webhook-token-env VAR] [--latency-ms N] [--query-failure-rate R] [--enable-disabled] [--dry-run]
#   spice-launch.sh fire-drill [DIR] [--timeout SECS] [--webhook-token-env VAR | --webhook-no-token]
#                             sends firing and recovery notifications; requires user approval
#   spice-launch.sh handoff   [DIR]
#   spice-launch.sh status    [DIR]
#   spice-launch.sh pause     [DIR]
#   spice-launch.sh teardown  [DIR] --yes [--keep-project]
#
# DIR defaults to the current directory and must hold spicepod.yaml. Progress
# goes to stderr; each command prints one JSON result on stdout and exits 0 on
# success, 1 on failure or a blocker (the JSON names it and the next step).
# Secret values, Management API tokens, and project API keys are never printed,
# written to files, or passed on a command line.

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by spice-launch.sh" >&2
  exit 1
fi

SPICE_LAUNCH_SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export SPICE_LAUNCH_SKILL_DIR

exec python3 - "$@" <<'PY'
import argparse
import hashlib
import json
import math
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = os.environ.get("SPICE_LAUNCH_API", "https://api.spice.ai")
OAUTH_URL = os.environ.get("SPICE_LAUNCH_OAUTH_URL", "https://spice.ai/api/oauth/token")
PORTAL = "https://spice.ai"
REGION_ENDPOINTS = {"us-east-1": "https://us-east-1-prod-aws-data.spiceai.io",
                    "us-west-2": "https://us-west-2-prod-aws-data.spiceai.io"}
STATE_DIR = ".spice-launch"
PREFIX = "launch: "
DRILL = PREFIX + "fire drill"
ANSI = re.compile(r"\x1b\[[0-9;]*m")
SECRET_REF = re.compile(r"\$\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z0-9_.\-/]+)\s*\}")
SECRET_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
PROJECT_NAME = re.compile(r"^[A-Za-z0-9-]{4,38}$")
# Spice Cloud management credentials. They never become runtime secrets.
CREDENTIAL_VAR = re.compile(r"^(SPICE_SPICEAI_(TOKEN|API_KEY)(_\w+)?|SPICE_CLOUD_CLIENT_(ID|SECRET)|SPICE_API_TOKEN)$")
# Org secrets Spice.ai Cloud manages itself: linkable to a project, but never listed.
PLATFORM_SECRETS = {"SCP_OPENAI_API_KEY": "the OpenAI credit ($25) Spice.ai Cloud gives a new account"}
LOCAL = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # the local runtime: never proxied
REMOTE = urllib.request.build_opener()                               # Spice Cloud: honor HTTPS_PROXY


def status(msg):
    print(msg, file=sys.stderr, flush=True)


def emit(obj, ok=True):
    print(json.dumps({"ok": ok, **obj}, indent=2, default=str))
    sys.exit(0 if ok else 1)


def fail(msg, **extra):
    status(f"Error: {msg}")
    emit({"error": msg, **extra}, ok=False)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# ---------------------------------------------------------------- HTTP


def http(method, url, body=None, headers=None, timeout=30, opener=REMOTE):
    data = body.encode() if isinstance(body, str) else body
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with opener.open(request, timeout=timeout) as response:
            return response.status, response.read().decode(errors="replace"), {k.lower(): v for k, v in response.headers.items()}
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode(errors="replace"), {k.lower(): v for k, v in (err.headers or {}).items()}
    except (urllib.error.URLError, OSError, TimeoutError) as err:
        return None, str(getattr(err, "reason", err)), {}


def as_json(text):
    try:
        return json.loads(text) if text else None
    except ValueError:
        return text


def error_text(data):
    if isinstance(data, dict):
        for key in ("code", "error", "message"):
            if data.get(key):
                value = data[key]
                return value if isinstance(value, str) else json.dumps(value)
    return str(data)[:300] if data else "no response body"


# ---------------------------------------------------------------- local files and credentials


def read_env_file(path):
    """KEY=VALUE lines, as `.env` files are written: optional `export`, quotes, comments."""
    values = {}
    try:
        text = Path(path).read_text()
    except OSError:
        return values
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        else:
            value = re.sub(r"\s+#.*$", "", value)
        values[key] = value
    return values


def local_env(d):
    """The process environment wins over .env.local, which wins over .env."""
    merged = read_env_file(d / ".env")
    merged.update(read_env_file(d / ".env.local"))
    merged.update({k: v for k, v in os.environ.items() if v})
    return merged


def org_token_var(org):
    """The variable `spice cloud login` stores an org's credential under (`acme` -> ..._ACME)."""
    encoded = "".join(c.upper() if c.isascii() and c.isalnum() else f"_{ord(c):02X}" for c in org)
    return f"SPICE_SPICEAI_TOKEN_{encoded}"


def keychain_read(var):
    """The macOS keychain item `spice cloud login` writes (service VAR, account `spice`)."""
    if sys.platform != "darwin" or not shutil.which("security"):
        return None
    try:
        r = subprocess.run(["security", "find-generic-password", "-s", var, "-a", "spice", "-w"],
                           capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() or None if r.returncode == 0 else None


def oauth_exchange(client_id, client_secret):
    body = json.dumps({"client_id": client_id, "client_secret": client_secret, "grant_type": "client_credentials"})
    code, text, _ = http("POST", OAUTH_URL, body, {"Content-Type": "application/json"})
    data = as_json(text)
    if code == 200 and isinstance(data, dict) and data.get("access_token"):
        return data["access_token"], None
    return None, f"OAuth client-credentials exchange failed (HTTP {code}: {error_text(data)})"


def resolve_token(d, org):
    """Return (token, source, problems). Order: explicit token, OAuth client, then the CLI's own login."""
    env = local_env(d)
    problems = []
    if env.get("SPICE_API_TOKEN"):
        return env["SPICE_API_TOKEN"], "SPICE_API_TOKEN", problems
    if env.get("SPICE_CLOUD_CLIENT_ID") and env.get("SPICE_CLOUD_CLIENT_SECRET"):
        token, problem = oauth_exchange(env["SPICE_CLOUD_CLIENT_ID"], env["SPICE_CLOUD_CLIENT_SECRET"])
        if token:
            return token, "OAuth client (SPICE_CLOUD_CLIENT_ID)", problems
        problems.append(problem)
    names = ([org_token_var(org)] if org else []) + ["SPICE_SPICEAI_TOKEN"]
    for name in names:
        if env.get(name):
            return env[name], f"{name} (environment or .env)", problems
    for name in names:
        token = keychain_read(name)
        if token:
            return token, f"{name} (keychain item written by `spice cloud login`)", problems
    return None, None, problems


TOKEN_HELP = [
    "Ask whether the user has a Spice.ai account, then run `spice-launch.sh login DIR`: it starts a device login and "
    "returns a URL and a one-time code for the user to open and approve. On that page, Continue with GitHub signs in, "
    "and creates the account for a new user (a GitHub account is required). Then run `spice-launch.sh login DIR --wait`.",
    "Unattended use (CI, scheduled checks): an OAuth client (organization Settings -> OAuth Clients) with apps, "
    "deployments, secrets, monitors and reactions read/write scopes, as SPICE_CLOUD_CLIENT_ID and "
    "SPICE_CLOUD_CLIENT_SECRET in the environment or .env.local. SPICE_API_TOKEN (a personal access token from "
    "https://spice.ai/account/tokens) also works.",
]


# ---------------------------------------------------------------- context and state


def project_dir(value):
    return Path(value or ".").expanduser().resolve()


def find_pod(d):
    for name in ("spicepod.yaml", "spicepod.yml"):
        if (d / name).is_file():
            return d / name
    return None


def parse_ref(ref):
    org, sep, name = (ref or "").partition("/")
    if not sep or not org or not name or "/" in name:
        fail(f"expected ORG/PROJECT, got {ref!r}")
    return org, name


class Ctx:
    def __init__(self, a, need_project=True):
        self.dir = project_dir(getattr(a, "dir", None))
        self.state_file = self.dir / STATE_DIR / "state.json"
        try:
            self.state = json.loads(self.state_file.read_text())
        except (OSError, ValueError):
            self.state = {}
        ref = getattr(a, "project", None) or self.state.get("project_ref")
        self.org, self.name = parse_ref(ref) if ref else (None, None)
        if need_project and not ref:
            fail(f"no project for {self.dir}: pass --project ORG/NAME", next="spice-launch.sh create DIR --project ORG/NAME")
        self.ref = ref
        self.cli = shutil.which("spice") or next(
            (str(p) for p in [Path.home() / ".spice" / "bin" / "spice"] if p.is_file() and os.access(p, os.X_OK)), None)
        self._token = None
        self.token_source = None

    def token(self):
        if self._token is None:
            token, source, problems = resolve_token(self.dir, self.org)
            if not token:
                fail("no Spice Cloud Management API credential found", blocker="management_token_missing",
                     problems=problems, hints=TOKEN_HELP)
            self._token, self.token_source = token, source
        return self._token

    def save(self, **fields):
        self.state.update(fields)
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.state_file.write_text(json.dumps(self.state, indent=2, default=str))

    def project_id(self):
        pid = self.state.get("project_id")
        if pid:
            return pid
        found = find_project(self, self.name)
        if not found:
            fail(f"project {self.ref} does not exist", next=f"spice-launch.sh create {self.dir} --project {self.ref}")
        self.save(project_ref=self.ref, project_id=found["id"])
        return found["id"]


def api(ctx, method, path, body=None, timeout=45, retries=2, org=True):
    headers = {"Authorization": f"Bearer {ctx.token()}", "Accept": "application/json"}
    if org and ctx.org:
        headers["X-Org-Name"] = ctx.org
    payload = json.dumps(body) if body is not None else None
    if payload is not None:
        headers["Content-Type"] = "application/json"
    for attempt in range(retries + 1):
        code, text, _ = http(method, API + path, payload, headers, timeout)
        if (code is None or code in (429, 502, 503, 504)) and attempt < retries:
            time.sleep(3 * (attempt + 1))
            continue
        break
    if code == 401:
        fail("the Management API rejected the credential (401)", token_source=ctx.token_source,
             hints=["The token expired or was revoked: `spice-launch.sh login DIR --force` signs in again."] + TOKEN_HELP)
    return code, as_json(text)


def find_project(ctx, name):
    code, data = api(ctx, "GET", "/v1/projects")
    if code != 200:
        fail(f"could not list projects in {ctx.org} (HTTP {code}: {error_text(data)})")
    for project in data.get("projects", []) if isinstance(data, dict) else []:
        if str(project.get("name", "")).lower() == name.lower():
            return project
    return None


def get_project(ctx, pid):
    code, data = api(ctx, "GET", f"/v1/projects/{pid}")
    if code != 200 or not isinstance(data, dict):
        fail(f"could not read project {pid} (HTTP {code}: {error_text(data)})")
    return data


def org_id(ctx):
    """The numeric id of ctx.org, which the org-level routes need."""
    code, data = api(ctx, "GET", "/v1/orgs", org=False)
    rows = data.get("orgs", []) if isinstance(data, dict) else []
    match = next((o for o in rows if str(o.get("name", "")).lower() == str(ctx.org or "").lower()), None)
    return match.get("id") if match else None


def org_secret_names(ctx, oid=None):
    """Names of the organization's secrets, or None when this credential cannot list them."""
    oid = oid or org_id(ctx)
    if not oid:
        return None
    code, data = api(ctx, "GET", f"/v1/orgs/{oid}/secrets")
    if code != 200 or not isinstance(data, dict):
        return None
    return {s.get("name") for s in data.get("secrets", []) if isinstance(s, dict)}


def linked_org_secrets(ctx, pid):
    """Names of the org secrets linked to the project, or None when they cannot be listed."""
    code, data = api(ctx, "GET", f"/v1/projects/{pid}/org-secrets")
    if code != 200 or not isinstance(data, dict):
        return None
    return {s.get("name") for s in data.get("org_secrets", []) if isinstance(s, dict)}


# ---------------------------------------------------------------- the spice CLI


def parse_json_tail(text):
    """The JSON document in CLI output, skipping any announcement lines before it."""
    text = text.strip()
    try:
        return json.loads(text)
    except ValueError:
        pass
    decoder = json.JSONDecoder()
    found = None
    for match in re.finditer(r"^[\[{]", text, re.M):
        try:
            found, _ = decoder.raw_decode(text[match.start():])
        except ValueError:
            continue
    return found


def cli(ctx, *args, timeout=180, want_json=True):
    """Run the CLI as the same identity as the API calls by handing it the resolved token."""
    if not ctx.cli:
        fail("the Spice CLI is not installed or not on PATH", blocker="cli_missing",
             docs="https://spiceai.org/docs/installation")
    env = dict(os.environ)
    if args and args[0] == "cloud" and ctx.org:
        env[org_token_var(ctx.org)] = ctx.token()
    try:
        r = subprocess.run([ctx.cli, *args], cwd=ctx.dir, capture_output=True, text=True,
                           timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, f"`spice {' '.join(args[:3])}` timed out after {timeout}s"
    except OSError as err:
        return None, str(err)
    out, err = ANSI.sub("", r.stdout), ANSI.sub("", r.stderr)
    if not want_json:
        return out, (None if r.returncode == 0 else (err or out).strip()[-1500:])
    data = parse_json_tail(out)
    if isinstance(data, dict) and data.get("status") == "error":
        problem = data.get("error") or {}
        return data, problem.get("message") if isinstance(problem, dict) else str(problem)
    if r.returncode != 0 or data is None:
        return data, (err or out).strip()[-1500:] or f"exit code {r.returncode}"
    return data, None


def validate(ctx):
    out, err = cli(ctx, "validate", str(ctx.dir), want_json=False, timeout=60)
    text = (out or err or "").strip()
    counts = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", text)}
    return err is None, counts, text


def cloud_status(ctx):
    data, _ = cli(ctx, "cloud", "status", "--project", ctx.ref, "-o", "json", timeout=90)
    return data if isinstance(data, dict) else {}


def instances(ctx):
    rows = cloud_status(ctx).get("instances") or []
    return sorted((i for i in rows if isinstance(i, dict) and i.get("name")), key=lambda i: i.get("startTime") or "")


def instance_logs(ctx, instance=None, limit=300):
    data, _ = cli(ctx, "cloud", "logs", "--project", ctx.ref, "--limit", str(limit), "-o", "json", timeout=90)
    rows = data.get("logs", []) if isinstance(data, dict) else []
    lines = []
    for row in rows:
        if instance and row.get("source") and row.get("source") != instance:
            continue
        lines.extend(ANSI.sub("", str(row.get("message", ""))).splitlines())
    return lines


def instance_datasets(ctx, instance):
    data, _ = cli(ctx, "cloud", "datasets", "--project", ctx.ref, "--instance", instance, "-o", "json", timeout=90)
    return data if isinstance(data, list) else []


def secrets_preflight(lines):
    """The runtime's startup secret check: `Secrets: all N ... resolved` or `K of N ... could not be resolved`."""
    for i, line in enumerate(lines):
        if "secrets_preflight" not in line:
            continue
        if "resolved." in line and "could not" not in line:
            return {"resolved": True, "unresolved": []}
        unresolved = []
        for follow in lines[i:i + 60]:
            m = re.search(r"✗\s*\$\{\s*\w+:(\S+?)\s*\}\s+(.*?)\s+—\s+(.*)", follow)
            if m:
                unresolved.append({"secret": m.group(1), "used_by": m.group(2), "reason": m.group(3)})
        return {"resolved": not unresolved, "unresolved": unresolved}
    return None


def problem_lines(lines):
    seen, keep = set(), []
    for line in lines:
        if not re.search(r"\b(WARN|ERROR)\b", line):
            continue
        key = re.sub(r"^\S+\s+", "", line)[:160]
        if key not in seen:
            seen.add(key)
            keep.append(line[:500])
    return keep


def hints_for(lines, datasets=(), local=False):
    text = "\n".join(lines) + "\n" + "\n".join(str(d.get("error_message") or d.get("error") or "") for d in datasets)
    hints = []
    if "could not be resolved" in text or "not found in any configured secret store" in text:
        hints.append("A secret is not set locally. Put it in .env.local to run it here; components that use it are "
                     "checked by the Cloud deploy instead." if local else
                     "A secret is missing in Cloud. `spice-launch.sh secrets DIR` links the org secret of that name to "
                     "the project, or stores the value from your environment or .env as a project secret; then deploy "
                     "again.")
    if "TLS handshake" in text:
        hints.append("Postgres TLS failed before authentication. pg_sslmode defaults to verify-full: the server "
                     "certificate must be valid, unexpired, and match the host (check with `openssl s_client -starttls "
                     "postgres -connect HOST:5432`), or provide pg_sslrootcert. The same error means the server offers "
                     "no TLS at all (`psql \"host=HOST sslmode=require\"` says 'server does not support SSL'): then only "
                     "pg_sslmode: disable connects, in plaintext, which is acceptable only for public data. Use "
                     "pg_sslmode: require only for a demo database.")
    if "Client asked for SSL but server does not have this capability" in text:
        hints.append("The MySQL server offers no TLS, and mysql_sslmode defaults to required (verified TLS); preferred "
                     "does not fall back to plaintext either. Enable TLS on the server, or set mysql_sslmode: disabled "
                     "(plaintext, acceptable only for public data).")
    if "Access denied for user" in text:
        hints.append("MySQL rejected the login: check mysql_user and mysql_pass, and that the user may connect from "
                     "outside the server's network (its host part and any IP allowlist).")
    if re.search(r"PostgreSQL connection failed\.\s*(db error|Timed out in bb8)", text) or "too many connections" in text \
            or "remaining connection slots" in text or "query_wait_timeout" in text:
        hints.append("Postgres refused the session. Reproduce it with psql to see the reason. `query_wait_timeout` "
                     "(PgBouncer) and 'too many connections' mean the server is out of connections: each dataset keeps "
                     "its own pool (connection_pool_size, default 5; pg_connection_pool_min_idle, default 1), so lower "
                     "both for a shared server. An instance whose deployment stays in_progress keeps its connections "
                     "until a new deployment supersedes it or the project is paused.")
    if "Disk full (/tmp" in text:
        hints.append("The MySQL server ran out of temporary space while answering the runtime's information_schema "
                     "metadata query. The server's operator must free space; until then use another server.")
    if any(str(d.get("status")) == "Initializing" for d in datasets):
        hints.append("A federated dataset stays Initializing while the runtime waits on the source: a firewall dropping "
                     "packets, or a slow metadata query. On a MySQL 5.x or MariaDB 10.0 server that hosts thousands of "
                     "databases, the runtime's information_schema read scans every database and can take many minutes: "
                     "connect as a user granted only the databases the spicepod uses, or use MySQL 8.0 or later.")
    if "insufficient_quota" in text or "exceeded your current quota" in text:
        hints.append("The OpenAI key has no quota left. With SCP_OPENAI_API_KEY, the $25 credit Spice.ai Cloud gives a "
                     "new account is used up: reference the user's own key instead (an org secret, or a value in "
                     ".env.local), then run secrets and deploy again.")
    if "Failed to load LLM" in text or "Failed to load embedding" in text:
        hints.append("A model failed to load (bad key, unknown model id, or quota). Fix it and deploy again; until then "
                     "the runtime never becomes ready and the deployment stays in_progress.")
    if "Memory usage at" in text:
        hints.append("The instance ran short of memory while loading accelerations. Federate large tables (drop "
                     "acceleration), narrow them with refresh_sql or refresh_data_window, or raise the memory limit "
                     "(`spice cloud project update --memory 8Gi`, within plan limits).")
    if "Received redirect without LOCATION" in text:
        hints.append("Wrong S3 region: set s3_region to the bucket's region.")
    if "InvalidAccessKeyId" in text or "AccessDenied" in text:
        hints.append("S3 rejected the credentials: use s3_auth: public for public buckets, or check s3_key/s3_secret.")
    if "Failed to authenticate with Snowflake" in text:
        hints.append("Snowflake rejected the login: check snowflake_account (orgname-account), user, password or key, "
                     "and that the warehouse exists and the role can use it.")
    if "No data files are yet available" in text or "Failed to find any files" in text:
        hints.append("The S3 path or file_format matches no files. Check the prefix and file_format.")
    if "replication slots are in use" in text:
        hints.append("The source Postgres has no free replication slot for refresh_mode: changes. Drop unused slots or "
                     "use refresh_mode: full with refresh_check_interval.")
    return hints


# ---------------------------------------------------------------- spicepod facts


def strip_comments(text):
    """Drop YAML comments (whole-line `#`, and ` # ...` outside quotes) so commented-out templates don't count."""
    kept = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        quote, cut = None, len(line)
        for i, ch in enumerate(line):
            if quote:
                quote = None if ch == quote else quote
            elif ch in "'\"":
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                cut = i
                break
        kept.append(line[:cut])
    return "\n".join(kept)


def references(text):
    refs = {}
    for store, key in SECRET_REF.findall(strip_comments(text)):
        refs.setdefault(key, set()).add(store)
    return refs


def components(spec):
    names = lambda key: [x["name"] for x in spec.get(key) or [] if isinstance(x, dict) and x.get("name")]
    return {"datasets": names("datasets"), "views": names("views"), "models": names("models"),
            "embeddings": names("embeddings"), "catalogs": names("catalogs")}


def accelerated(ds):
    acc = ds.get("acceleration")
    return isinstance(acc, dict) and acc.get("enabled", True) is not False


# TLS modes that encrypt without verifying the server, or not at all, and what production should use instead.
WEAK_TLS = {
    "postgres": ("pg_sslmode", "verify-full", "verify-full (with pg_sslrootcert if the CA is private)", {
        "disable": "sends credentials and data in plaintext",
        "allow": "can connect in plaintext and never verifies the server certificate",
        "prefer": "can connect in plaintext and never verifies the server certificate",
        "require": "encrypts but does not verify the server certificate"}),
    "mysql": ("mysql_sslmode", "required", "required, the default (with mysql_sslrootcert if the CA is private)", {
        "disabled": "sends credentials and data in plaintext",
        "preferred": "encrypts but does not verify the server certificate or host name"}),
}


def merge_notes(notes):
    """One note per (level, code, message), listing every dataset it applies to."""
    merged = {}
    for note in notes:
        key = (note["level"], note["code"], note["message"])
        entry = merged.setdefault(key, {k: v for k, v in note.items() if k != "dataset"})
        if note.get("dataset"):
            entry.setdefault("datasets", []).append(note["dataset"])
    return list(merged.values())


def lint(spec, profile):
    notes = []
    runtime = spec.get("runtime") or {}
    hosts = (runtime.get("mcp") or {}).get("allowed_hosts") or []
    if "*" not in hosts:
        notes.append({"level": "warn", "code": "mcp_allowed_hosts",
                      "message": "Without runtime.mcp.allowed_hosts: [\"*\"], /v1/mcp answers 403 'Host header is not "
                                 "allowed' on Spice Cloud, and listing the public hostname does not help. Project API "
                                 "keys still guard the endpoint."})
    for ds in spec.get("datasets") or []:
        if not isinstance(ds, dict):
            continue
        name, source = ds.get("name"), str(ds.get("from", ""))
        params, acc = ds.get("params") or {}, ds.get("acceleration") or {}
        connector = source.split(":", 1)[0]
        if connector in WEAK_TLS:
            param, default, better, weak = WEAK_TLS[connector]
            mode = str(params.get(param, default))
            if mode in weak:
                notes.append({"level": "warn" if profile == "production" else "info", "code": param, "dataset": name,
                              "message": f"{param} {mode} {weak[mode]}; production should use {better}."})
        if source.startswith("s3://") and "s3_auth" not in params:
            notes.append({"level": "info", "code": "s3_auth", "dataset": name,
                          "message": "Set s3_auth explicitly (public for public buckets, key or iam_role otherwise); "
                                     "unset, ambient AWS credentials are tried first and can break public reads."})
        if accelerated(ds):
            if acc.get("refresh_check_interval") and acc.get("refresh_cron"):
                notes.append({"level": "error", "code": "refresh_both", "dataset": name,
                              "message": "refresh_check_interval and refresh_cron together drop the dataset."})
            if not acc.get("refresh_check_interval") and not acc.get("refresh_cron") and \
                    acc.get("refresh_mode") not in ("changes", "append", "caching", "snapshot"):
                notes.append({"level": "info", "code": "no_refresh", "dataset": name,
                              "message": "Accelerated once at startup and never refreshed; set refresh_check_interval "
                                         "if the source changes."})
            if acc.get("engine") in ("duckdb", "sqlite", "turso", "cayenne") and acc.get("mode", "memory") != "memory":
                notes.append({"level": "info", "code": "file_mode", "dataset": name,
                              "message": "File-mode acceleration on Spice Cloud needs persistent storage (storage_size_gb, "
                                         "Enterprise); otherwise the file is rebuilt from the source after each restart."})
    for model in spec.get("models") or []:
        if isinstance(model, dict) and not (model.get("params") or {}).get("tools"):
            notes.append({"level": "info", "code": "model_tools", "model": model.get("name"),
                          "message": "No `tools` param: chat answers cannot query data. MCP clients are unaffected."})
    if profile == "production" and not (runtime.get("query") or {}).get("timeout"):
        notes.append({"level": "info", "code": "query_timeout",
                      "message": "Set runtime.query.timeout (e.g. 30s) so one runaway agent query cannot hold the instance."})
    return notes


PRIVATE_HOST = re.compile(r"^(localhost|127\.|0\.0\.0\.0|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$|"
                          r"host\.docker\.internal)|\.(local|internal|lan|localdomain)$", re.I)
LOCAL_SOURCES = ("file:", "file/", "duckdb:", "sqlite:", "localpod:")


def reachability(spec):
    """Errors for sources that a Spice Cloud instance cannot reach."""
    errors = []
    for ds in spec.get("datasets") or []:
        if not isinstance(ds, dict):
            continue
        source, params = str(ds.get("from", "")), ds.get("params") or {}
        if source.startswith(LOCAL_SOURCES):
            errors.append({"level": "error", "code": "local_source", "dataset": ds.get("name"),
                           "message": f"`{source}` reads the runtime's own disk, and a Spice Cloud instance has no copy "
                                      "of local files. Upload them to object storage (s3://...) and point the dataset there."})
        for key, value in params.items():
            if not isinstance(value, str) or "${" in value:
                continue
            host = value
            if key.endswith(("_endpoint", "endpoint", "_url")) or "://" in value:
                host = re.sub(r"^[a-z][a-z0-9+.-]*://", "", value).split("/")[0].split("@")[-1]
            elif not key.endswith("_host"):
                continue
            host = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
            if PRIVATE_HOST.search(host):
                errors.append({"level": "error", "code": "private_host", "dataset": ds.get("name"), "param": key,
                               "message": f"{key}: {host} is a private or local address that Spice Cloud cannot reach. "
                                          "Use an endpoint reachable from the internet (TLS, a read-only user), or keep "
                                          "this source on a self-hosted runtime."})
    return errors


def quote_ident(name):
    return ".".join('"' + part.replace('"', '""') + '"' for part in str(name).split("."))


# ---------------------------------------------------------------- the data plane


def data_plane(ctx):
    project = get_project(ctx, ctx.project_id())
    region = (project.get("config") or {}).get("region")
    endpoint = (project.get("endpoint") or REGION_ENDPOINTS.get(region) or "").rstrip("/")
    if not endpoint:
        fail(f"project {ctx.ref} has no data-plane endpoint yet", next=f"spice-launch.sh deploy {ctx.dir}")
    code, keys = api(ctx, "GET", f"/v1/projects/{ctx.project_id()}/api-keys")
    key = keys.get("api_key") if isinstance(keys, dict) else None
    if code != 200 or not key:
        fail(f"could not read the project API key (HTTP {code}: {error_text(keys)})")
    return endpoint, key, project


def dp(endpoint, key, method, path, body=None, content_type=None, accept="application/json", timeout=60, extra=None,
       opener=REMOTE):
    headers = {**({"X-API-Key": key} if key else {}), "Accept": accept, **(extra or {})}
    if content_type:
        headers["Content-Type"] = content_type
    return http(method, endpoint + path, body, headers, timeout, opener=opener)


def served(endpoint, key):
    code, text, _ = dp(endpoint, key, "GET", "/v1/datasets?status=true")
    datasets = as_json(text) if code == 200 else None
    code_m, text_m, _ = dp(endpoint, key, "GET", "/v1/models?status=true")
    models = as_json(text_m) if code_m == 200 else None
    if isinstance(models, dict):
        models = models.get("data")
    return (datasets if isinstance(datasets, list) else []), (models if isinstance(models, list) else [])


def sql(endpoint, key, query, timeout=60, nocache=False, opener=REMOTE):
    extra = {"Cache-Control": "no-cache"} if nocache else None
    code, text, _ = dp(endpoint, key, "POST", "/v1/sql", query, "text/plain", timeout=timeout, extra=extra, opener=opener)
    return code, as_json(text)


def sse_json(text):
    frames = re.findall(r"^data: (\{.*\})\s*$", text or "", re.M)
    return as_json(frames[-1]) if frames else as_json(text)


# ---------------------------------------------------------------- commands: preflight, local, create, secrets


def cmd_preflight(a):
    ctx = Ctx(a, need_project=False)
    blockers, warnings, result = [], [], {"dir": str(ctx.dir), "project": ctx.ref}
    if not ctx.cli:
        blockers.append({"blocker": "cli_missing", "docs": "https://spiceai.org/docs/installation",
                         "message": "The Spice CLI is not installed. Installation is user-managed."})
    else:
        r = subprocess.run([ctx.cli, "version", "-o", "json"], capture_output=True, text=True, timeout=60)
        version = parse_json_tail(ANSI.sub("", r.stdout)) or {}
        result["cli"] = {"path": ctx.cli, "version": version.get("cli"), "runtime": version.get("runtime")}
    token, source, problems = resolve_token(ctx.dir, ctx.org)
    org_names, project_names, linked = None, None, None
    if not token:
        blockers.append({"blocker": "management_token_missing", "problems": problems, "hints": TOKEN_HELP})
    else:
        ctx._token, ctx.token_source = token, source
        result["credential"] = source
        code, orgs = api(ctx, "GET", "/v1/orgs", org=False)
        rows = orgs.get("orgs", []) if isinstance(orgs, dict) else []
        result["orgs_visible"] = len(rows)
        if not ctx.org:
            result["orgs"] = [{"name": o.get("name"), "role": o.get("role")} for o in rows][:50]
        if ctx.org:
            match = next((o for o in rows if str(o.get("name", "")).lower() == ctx.org.lower()), None)
            if not match:
                blockers.append({"blocker": "org_not_accessible", "message": f"The credential cannot act on {ctx.org}.",
                                 "hint": "An OAuth client is pinned to the org that issued it; a user token reaches "
                                         "every org the user belongs to."})
            else:
                result["role"] = match.get("role")
                if match.get("role") not in ("owner", "admin"):
                    warnings.append("Updating monitors needs organization admin; this credential's role is "
                                    f"{match.get('role')}.")
                code, limits = api(ctx, "GET", "/v1/limits")
                if code == 200:
                    result["limits"] = {k: limits.get(k) for k in ("replicas", "request_timeout_secs",
                                                                   "sql_query_timeout_secs", "resources")}
                    result["private_compute"] = limits.get("resources") is not None
                    if not result["private_compute"]:
                        warnings.append("No private compute: CPU and memory cannot be changed (spice cloud project "
                                        "update --cpu/--memory is refused), so size accelerations to the default "
                                        "instance (4 GiB in testing).")
                code, regions = api(ctx, "GET", "/v1/regions")
                if code == 200:
                    result["regions"] = [r["region"] for r in regions.get("regions", []) if not r.get("disabled")]
                org_names = org_secret_names(ctx, match.get("id"))
                if ctx.name:
                    existing = find_project(ctx, ctx.name)
                    result["project_exists"] = bool(existing)
                    if existing:
                        result["project_id"] = existing["id"]
                        linked = linked_org_secrets(ctx, existing["id"])
                        code, data = api(ctx, "GET", f"/v1/projects/{existing['id']}/secrets")
                        if code == 200 and isinstance(data, dict):
                            project_names = {s.get("name") for s in data.get("secrets", []) if isinstance(s, dict)}
    pod = find_pod(ctx.dir)
    if not pod:
        warnings.append("No spicepod.yaml yet: design it, then run create.")
    elif ctx.cli:
        ok, counts, text = validate(ctx)
        result["spicepod"] = {"path": str(pod), "valid": ok, "components": counts}
        if not ok:
            blockers.append({"blocker": "spicepod_invalid", "validate": text[-1500:]})
        env = local_env(ctx.dir)
        refs = []
        for key, stores in sorted(references(pod.read_text()).items()):
            name = key.upper()
            ref = {"name": name, "stores": sorted(stores), "available_locally": bool(env.get(key) or env.get(name))}
            for field, names in (("org_secret", org_names), ("project_secret", project_names), ("linked", linked)):
                if names is not None:
                    ref[field] = name in names
            if name in PLATFORM_SECRETS:
                ref["platform_secret"] = (f"{PLATFORM_SECRETS[name]}: never listed; `secrets` links it after create, "
                                          "or reports it missing if this organization has none")
            refs.append(ref)
            if stores & {"secrets", "env"} and not CREDENTIAL_VAR.match(name) and not ref["available_locally"] and \
                    org_names is not None and not ref["org_secret"] and not ref.get("project_secret") and \
                    name not in PLATFORM_SECRETS:
                warnings.append(f"{name} is not set locally, and {ctx.org} has no org secret of that name: get the value "
                                "from the user (environment or .env.local) or have them create the org secret.")
        result["secret_references"] = refs
    result["blockers"], result["warnings"] = blockers, warnings
    if blockers:
        result["next"] = "Resolve the blockers; installation and Cloud credentials are the user's to provide."
    elif not pod:
        result["next"] = "Design spicepod.yaml for the scenario (see references/scenarios.md)."
    else:
        result["next"] = f"spice-launch.sh create {ctx.dir} --project ORG/NAME" if not ctx.ref else \
            f"spice-launch.sh create {ctx.dir} --project {ctx.ref}"
    emit(result, ok=not blockers)


DEVICE_CODE = re.compile(r"^\s*([A-Z0-9]{4}-[A-Z0-9]{4})\s*$", re.M)
DEVICE_URL = re.compile(r"(https://\S+/auth/token\?code=[A-Za-z0-9]+)")


def working_credential(ctx):
    """(source, orgs) for a stored credential the Management API accepts, else (None, problems)."""
    token, source, problems = resolve_token(ctx.dir, ctx.org)
    if not token:
        return None, problems
    code, text, _ = http("GET", API + "/v1/orgs", None, {"Authorization": f"Bearer {token}", "Accept": "application/json"})
    if code != 200:
        return None, problems + [f"{source} was rejected (HTTP {code}: {error_text(as_json(text))})"]
    rows = (as_json(text) or {}).get("orgs", [])
    return source, [{"name": o.get("name"), "role": o.get("role")} for o in rows if isinstance(o, dict)]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError):
        return False


def cmd_login(a):
    """Sign in to Spice Cloud with the CLI's device flow, in two steps an agent can relay: start (URL and code), wait."""
    ctx = Ctx(a, need_project=False)
    log = ctx.dir / STATE_DIR / "login.log"
    started = ctx.state.get("login") or {}
    if a.wait:
        if not started.get("pid") or started.get("completed_at"):
            fail("no login is in progress", next=f"spice-launch.sh login {ctx.dir}")
        status("Waiting for the user to approve the login ...")
        deadline = time.time() + a.timeout
        while alive(started["pid"]) and time.time() < deadline:
            time.sleep(2)
        if alive(started["pid"]):
            fail("the login is still waiting for approval", url=started.get("url"),
                 note="The user opens the URL, signs in or signs up, and approves the code; the code expires 5 "
                      "minutes after login started.", next=f"spice-launch.sh login {ctx.dir} --wait")
        text = ANSI.sub("", log.read_text(errors="replace")) if log.exists() else ""
        # Judge this login by its own outcome, not by whatever credential was stored before it.
        granted = "Successfully logged in" in text or "Login token saved" in text
        source, found = working_credential(ctx) if granted else (None, [])
        if source:
            ctx.save(login={**started, "completed_at": now()})
            emit({"status": "logged_in", "credential": source, "orgs": found,
                  "next": f"spice-launch.sh preflight {ctx.dir} --project ORG/NAME (an org from `orgs`)"})
        fail("the login ended without a working credential", log_tail=text.splitlines()[-8:], problems=found,
             next=f"spice-launch.sh login {ctx.dir}  (starts a new code)")
    if not a.force:
        source, found = working_credential(ctx)
        if source:
            emit({"status": "logged_in", "credential": source, "orgs": found,
                  "note": "Already signed in; `--force` signs in again, e.g. as another user.",
                  "next": f"spice-launch.sh preflight {ctx.dir} --project ORG/NAME (an org from `orgs`)"})
    if not ctx.cli:
        fail("the Spice CLI is not installed or not on PATH", blocker="cli_missing", docs="https://spiceai.org/docs/installation")
    # The CLI saves the credential to the macOS keychain, or to .env in this directory (kept out of git).
    store = a.store or ("keychain" if sys.platform == "darwin" else "env")
    if store == "env":
        ensure_gitignore(ctx.dir)
    log.parent.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k != "SPICE_API_TOKEN"}
    with open(log, "w") as handle:
        proc = subprocess.Popen([ctx.cli, "cloud", "login", "-o", store, "subscription", "--device"], cwd=ctx.dir,
                                stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT, env=env,
                                start_new_session=True)  # keeps polling after this command returns
    code = url = None
    deadline = time.time() + 30
    while time.time() < deadline and proc.poll() is None and not url:
        text = ANSI.sub("", log.read_text(errors="replace"))
        match_code, match_url = DEVICE_CODE.search(text), DEVICE_URL.search(text)
        if match_code and match_url:
            code, url = match_code.group(1), match_url.group(1)
        else:
            time.sleep(0.5)
    if not url:
        if proc.poll() is None:
            proc.terminate()
        fail("the device login did not start", log_tail=ANSI.sub("", log.read_text(errors="replace")).splitlines()[-8:])
    ctx.save(login={"pid": proc.pid, "started_at": now(), "store": store, "url": url})
    emit({"status": "waiting_for_approval", "url": url, "code": code, "expires_in_secs": 300, "store": store,
          "note": "Give the user the URL and code, and wait for them. On the page, Continue with GitHub signs in, or "
                  "creates a Spice.ai account for a new user (a GitHub account is required); then they approve the "
                  "code, which must match.",
          "next": f"spice-launch.sh login {ctx.dir} --wait"})


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def cmd_local(a):
    """Smoke-run the spicepod on a local runtime with local secrets, then stop it."""
    ctx = Ctx(a, need_project=False)
    pod = find_pod(ctx.dir) or fail(f"no spicepod.yaml in {ctx.dir}")
    if not ctx.cli:
        fail("the Spice CLI is not installed", blocker="cli_missing")
    r = subprocess.run([ctx.cli, "version", "-o", "json"], capture_output=True, text=True, timeout=60)
    version = parse_json_tail(ANSI.sub("", r.stdout)) or {}
    if not version.get("runtime"):
        fail("no local runtime is installed, and `spice run` would download one", blocker="runtime_missing",
             next="Skip the local check (the Cloud deploy is still verified), or have the user install the runtime.")
    ok, counts, text = validate(ctx)
    if not ok:
        fail("spice validate failed", validate=text[-2000:])
    env = local_env(ctx.dir)
    missing = sorted(k.upper() for k, stores in references(pod.read_text()).items()
                     if stores & {"secrets", "env"} and not (env.get(k) or env.get(k.upper())))
    http_port, flight_port = free_port(), free_port()
    log = ctx.dir / STATE_DIR / "local-run.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    command = [ctx.cli, "run", "--http-endpoint", f"127.0.0.1:{http_port}", "--flight-endpoint", f"127.0.0.1:{flight_port}"]
    status(f"Starting a local runtime on 127.0.0.1:{http_port} (log {log}) ...")
    with open(log, "w") as handle:
        proc = subprocess.Popen(command, cwd=ctx.dir, stdin=subprocess.DEVNULL, stdout=handle,
                                stderr=subprocess.STDOUT, start_new_session=True)
    base = f"http://127.0.0.1:{http_port}"
    log_lines = lambda: log.read_text(errors="replace").splitlines() if log.exists() else []
    datasets, models, ready, settled, blocked, views, queries = [], [], False, 0, set(), [], []
    try:
        deadline = time.time() + a.timeout
        while time.time() < deadline and proc.poll() is None:
            code, body, _ = http("GET", base + "/v1/ready", timeout=3, opener=LOCAL)
            ready = code == 200 and body.strip() == "ready"
            code, body, _ = http("GET", base + "/v1/datasets?status=true", timeout=5, opener=LOCAL)
            datasets = as_json(body) if code == 200 else []
            datasets = datasets if isinstance(datasets, list) else []
            code, body, _ = http("GET", base + "/v1/models?status=true", timeout=5, opener=LOCAL)
            models = as_json(body) if code == 200 else []
            models = models.get("data", []) if isinstance(models, dict) else (models if isinstance(models, list) else [])
            # Components whose secret exists only in Cloud fail or wait here; the Cloud deploy checks them.
            blocked = {m.group(1) for row in (secrets_preflight(log_lines()) or {}).get("unresolved", [])
                       for m in [re.search(r"'([^']+)'", row.get("used_by", ""))] if m}
            pending = [d for d in datasets + models if d.get("status") in ("Initializing", "Refreshing", None)
                       and (d.get("name") or d.get("id")) not in blocked]
            settled = settled + 1 if len(datasets) >= counts.get("datasets", 0) and not pending else 0
            if ready or settled >= 3:
                break
            time.sleep(2)
        # Views register after the datasets load (and not at all while a dataset is in Error), then answer queries.
        names = {d.get("name") for d in datasets}
        views_deadline = time.time() + (30 if not any(d.get("status") == "Error" for d in datasets) else 6)
        while proc.poll() is None:
            code, rows = sql(base, "", "SELECT table_schema, table_name FROM information_schema.tables WHERE "
                                       "table_catalog = 'spice' AND table_schema NOT IN ('information_schema', 'runtime')",
                             opener=LOCAL)
            registered = {r.get("table_name") if r.get("table_schema") == "public" else
                          f"{r.get('table_schema')}.{r.get('table_name')}" for r in rows if isinstance(r, dict)} \
                if code == 200 and isinstance(rows, list) else set()
            views = sorted(registered - names)
            if len(views) >= counts.get("views", 0) or time.time() > views_deadline:
                break
            time.sleep(2)
        for name in [d.get("name") for d in datasets if d.get("status") == "Ready"] + views:
            t0 = time.perf_counter()
            code, rows = sql(base, "", f"SELECT * FROM {quote_ident(name)} LIMIT 1", timeout=60, opener=LOCAL)
            ok = code == 200 and isinstance(rows, list) and len(rows) > 0
            queries.append({"name": name, "kind": "view" if name in views else "dataset", "ok": ok,
                            "ms": round((time.perf_counter() - t0) * 1000), **({} if ok else {
                                "error": "no rows" if code == 200 else f"HTTP {code}: {error_text(rows)}"})})
        exited = proc.poll()
    finally:
        if proc.poll() is None:
            os.kill(proc.pid, signal.SIGTERM)  # `spice run` forwards it to spiced
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.kill(proc.pid, signal.SIGKILL)
    tail = log_lines()[-40:]
    rows = [{"name": d.get("name"), "status": d.get("status"), "error": d.get("error_message")}
            for d in datasets if isinstance(d, dict)]
    rows += [{"model": m.get("id") or m.get("name"), "status": m.get("status"), "error": m.get("error_message")}
             for m in models if isinstance(m, dict)]
    for row in rows:
        if (row.get("name") or row.get("model")) in blocked:
            row["needs_cloud_secret"] = True
    problems = [r for r in rows if r.get("status") != "Ready" and not r.get("needs_cloud_secret")]
    failed = [q for q in queries if not q["ok"]]
    blocked_datasets = blocked & {d.get("name") for d in datasets}
    unchecked_views = max(0, counts.get("views", 0) - len(views))
    result = {"ready": ready, "components": rows, "queries": queries, "missing_local_secrets": missing,
              "log": str(log), "stopped_pid": proc.pid, "runtime_exited_early": exited is not None and not ready}
    if unchecked_views:
        result["views_not_registered"] = unchecked_views
    next_step = f"spice-launch.sh create {ctx.dir} --project ORG/NAME" if not ctx.ref else f"spice-launch.sh deploy {ctx.dir}"
    if ready and not failed and not unchecked_views:
        emit({**result, "status": "ready_locally", "next": next_step})
    if not problems and not failed and (not unchecked_views or blocked_datasets):
        emit({**result, "status": "checked", "note": "Everything that does not need a Cloud-only secret loads and answers "
              "queries." + (f" Not checked here: {', '.join(sorted(blocked))} (secrets {', '.join(missing)} exist only in "
              "Spice Cloud); deploy and verify check them." if blocked else "") + (
              f" {unchecked_views} view(s) did not register while a dataset waits on a Cloud-only secret."
              if unchecked_views else ""), "next": next_step})
    fail("the spicepod does not fully work locally", **result, log_tail=tail[-15:],
         hints=hints_for(tail, problems, local=True) + ([
             f"{unchecked_views} view(s) never registered. Views wait until every dataset loads, so a dataset in Error "
             "keeps all of them away; fix it first."] if unchecked_views else []))


def ensure_gitignore(d):
    path = d / ".gitignore"
    wanted = [".env", ".env.local", f"{STATE_DIR}/", ".spice/"]
    lines = path.read_text().splitlines() if path.exists() else []
    missing = [w for w in wanted if w not in lines]
    if missing:
        with open(path, "a") as handle:
            handle.write(("\n" if lines and lines[-1] else "") + "# spice-launch: local secrets and state\n" +
                         "\n".join(missing) + "\n")
    return missing


def cmd_create(a):
    ctx = Ctx(a)
    if not PROJECT_NAME.match(ctx.name):
        fail(f"invalid project name {ctx.name!r}: 4-38 letters, numbers, or hyphens")
    pod = find_pod(ctx.dir) or fail(f"no spicepod.yaml in {ctx.dir}; design it first")
    ok, counts, text = validate(ctx)
    if not ok:
        fail("spice validate failed", validate=text[-2000:])
    existing = find_project(ctx, ctx.name)
    if existing:
        project = get_project(ctx, existing["id"])
        if project.get("kind") != "managed":
            fail(f"{ctx.ref} exists but is a {project.get('kind')} project, which Spice Cloud does not run",
                 hint="Pick another name, or delete it if it was created by mistake.")
        ctx.save(project_ref=ctx.ref, project_id=project["id"], profile=a.profile or ctx.state.get("profile", "poc"),
                 region=(project.get("config") or {}).get("region"))
        emit({"status": "existing", "project": ctx.ref, "id": project["id"], "kind": project.get("kind"),
              "created_by_launch": ctx.state.get("created_by_launch", False),
              "note": "Reusing the existing project; deploy replaces its stored spicepod.",
              "next": f"spice-launch.sh secrets {ctx.dir}"})
    profile = a.profile or "poc"
    description = a.description or f"Created by spice-launch ({profile})"
    if a.base:
        base_org, base_name = parse_ref(a.base)
        if base_org.lower() != ctx.org.lower():
            fail("a fork stays in its source's organization", base=a.base, project=ctx.ref)
        base = find_project(ctx, base_name) or fail(f"base project {a.base} not found")
        status(f"Forking {a.base} (inherits its project secrets and linked org secrets) ...")
        code, fork = api(ctx, "POST", f"/v1/projects/{base['id']}/forks", {"name": ctx.name, "region": a.region})
        if code not in (200, 201) or not isinstance(fork, dict):
            fail(f"fork failed (HTTP {code}: {error_text(fork)})")
        pid = fork["id"]
        ctx.save(project_ref=ctx.ref, project_id=pid, created_by_launch=True, base=a.base, profile=profile,
                 region=a.region, created_at=now())
        data, err = cli(ctx, "cloud", "project", "update", "--project", ctx.ref, "--spicepod", str(pod),
                        "--channel", a.channel, "--description", description, "-o", "json")
        if err:
            fail("forked, but could not replace the spicepod and channel", detail=err, project=ctx.ref,
                 next=f"spice-launch.sh deploy {ctx.dir}  (retries the spicepod upload)")
        state = "forked"
    else:
        status(f"Creating managed project {ctx.ref} in {a.region} ...")
        data, err = cli(ctx, "cloud", "project", "create", ctx.name, "--org", ctx.org, "--kind", "set",
                        "--region", a.region, "--channel", a.channel, "--spicepod", str(pod),
                        "--description", description, "-o", "json")
        if err or not isinstance(data, dict) or not data.get("id"):
            fail("project creation failed", detail=err or data)
        pid = data["id"]
        ctx.save(project_ref=ctx.ref, project_id=pid, created_by_launch=True, profile=profile, region=a.region,
                 created_at=now())
        state = "created"
    if a.replicas:
        data, err = cli(ctx, "cloud", "project", "update", "--project", ctx.ref, "--replicas", str(a.replicas), "-o", "json")
        if err:
            status(f"Warning: could not set replicas: {err}")
        elif a.replicas > 1:
            status("Note: with more than one replica, MCP sessions break (404 Session not found); "
                   "keep 1 replica if agents connect over MCP.")
    added = ensure_gitignore(ctx.dir)
    project = get_project(ctx, pid)
    emit({"status": state, "project": ctx.ref, "id": pid, "kind": project.get("kind"),
          "region": (project.get("config") or {}).get("region"), "channel": (project.get("config") or {}).get("update_channel"),
          "replicas": (project.get("config") or {}).get("replicas"), "portal": f"{PORTAL}/{ctx.org}/{ctx.name}",
          "gitignore_added": added, "next": f"spice-launch.sh secrets {ctx.dir}"})


def cmd_secrets(a):
    ctx = Ctx(a)
    pid = ctx.project_id()
    pod = find_pod(ctx.dir) or fail(f"no spicepod.yaml in {ctx.dir}")
    refs = references(pod.read_text())
    env = local_env(ctx.dir)
    code, data = api(ctx, "GET", f"/v1/projects/{pid}/secrets")
    if code != 200:
        fail(f"could not list project secrets (HTTP {code}: {error_text(data)})")
    names = {s.get("name") for s in data.get("secrets", [])} if isinstance(data, dict) else set()
    linked = linked_org_secrets(ctx, pid)  # None: this credential cannot list them
    org_names = org_secret_names(ctx)
    force = set(a.set or [])
    rows = []

    def push(row, value):
        code, resp = api(ctx, "POST", f"/v1/projects/{pid}/secrets", {"name": row["name"], "value": value})
        rows.append({**row, "status": "pushed" if code in (200, 201) else "push_failed",
                     **({} if code in (200, 201) else {"error": error_text(resp)})})

    for key, stores in sorted(refs.items()):
        name = key.upper()  # the env store upper-cases keys, and Cloud injects secrets as env
        row = {"name": name, "stores": sorted(stores)}
        if not stores & {"secrets", "env"}:
            rows.append({**row, "status": "external_store",
                         "note": "Resolved by a non-env secret store at runtime; not managed here."})
            continue
        if CREDENTIAL_VAR.match(name):
            rows.append({**row, "status": "refused", "note": "Spice Cloud management credentials never go to the runtime."})
            continue
        if not SECRET_NAME.match(name):
            rows.append({**row, "status": "invalid_name"})
            continue
        value = env.get(key) or env.get(name)
        if name in force or key in force:
            if value:
                push(row, value)
            else:
                rows.append({**row, "status": "push_failed", "error": "--set needs the value in the environment, "
                                                                      ".env.local, or .env"})
        elif name in names:
            rows.append({**row, "status": "project_secret"})
        elif linked is not None and name in linked:
            rows.append({**row, "status": "org_secret_linked"})
        elif org_names is not None and name in org_names:
            # An org secret reaches a project only through a link; a local value of the same name is not pushed,
            # so a personal key never shadows the organization's.
            code, resp = api(ctx, "PUT", f"/v1/projects/{pid}/org-secrets/{name}")
            ok = code in (200, 201)
            rows.append({**row, "status": "linked" if ok else "link_failed",
                         **({"error": f"HTTP {code}: {error_text(resp)}"} if not ok else {}),
                         **({"note": "The org secret is used, not the local value; `--set " + name + "` stores the "
                                     "local value as a project secret, which takes precedence."} if ok and value else {})})
        elif value:
            push(row, value)
        else:
            # Platform-managed org secrets (SCP_OPENAI_API_KEY) are linkable but never listed: the link is the test.
            code, resp = api(ctx, "PUT", f"/v1/projects/{pid}/org-secrets/{name}")
            if code in (200, 201):
                rows.append({**row, "status": "linked", **({"note": f"Platform-managed: {PLATFORM_SECRETS[name]}."}
                                                           if name in PLATFORM_SECRETS else {})})
            elif code == 404:
                rows.append({**row, "status": "missing", "note": f"Not a project secret, not an org secret of "
                             f"{ctx.org}, and not set locally." + (
                                 f" {name} is {PLATFORM_SECRETS[name]}; this organization does not have it (accounts "
                                 "created before the credit existed do not), so use the user's own key."
                                 if name in PLATFORM_SECRETS else "")})
            else:
                rows.append({**row, "status": "unverified" if code == 403 else "link_failed",
                             "error": f"HTTP {code}: {error_text(resp)}",
                             "note": "Could not check whether an org secret of this name exists; the runtime's startup "
                                     "check during deploy settles it."})
    failed = [r for r in rows if r["status"] in ("push_failed", "link_failed", "invalid_name", "missing")]
    unverified = [r["name"] for r in rows if r["status"] == "unverified"]
    result = {"project": ctx.ref, "secrets": rows, "unverified": unverified,
              "note": "Values come from the environment, .env.local, or .env and go only to the Management API; org "
                      "secrets are linked by name and their values never leave Spice Cloud.",
              "next": f"spice-launch.sh deploy {ctx.dir}"}
    if failed:
        fail("some secrets are not available to the project", **result, hints=[
            "missing: put the value in the environment or .env.local and run secrets again, or create an org secret "
            "of that name (organization Settings -> Secrets) and run secrets again to link it. A platform name such "
            "as SCP_OPENAI_API_KEY is reserved and cannot be created: point the spicepod at the user's own key.",
            "link_failed or push_failed with 403: the credential needs secrets:write and a role above viewer."])
    emit(result)


# ---------------------------------------------------------------- deploy


def confirm_serving(endpoint, key, expected, sources=None, timeout=120):
    """True once every dataset and model of the new spicepod is served and Ready, each dataset from the
    spicepod's source (views are not listed by the runtime; verify queries them)."""
    deadline = time.time() + timeout
    norm = lambda value: str(value or "").strip().rstrip("/")
    while True:
        datasets, models = served(endpoint, key)
        ds = {d.get("name"): d for d in datasets if isinstance(d, dict)}
        md = {(m.get("id") or m.get("name")): m for m in models if isinstance(m, dict)}
        missing = [n for n in expected["datasets"] if n not in ds]
        missing += [f"{n} (served from {ds[n].get('from')}, spicepod says {src})" for n, src in (sources or {}).items()
                    if n in ds and norm(ds[n].get("from")) != norm(src)]
        not_ready = [{"name": n, "status": ds[n].get("status"), "error": ds[n].get("error_message")}
                     for n in expected["datasets"] if n in ds and ds[n].get("status") != "Ready"]
        missing_models = [n for n in expected["models"] if n not in md]
        bad_models = [{"name": n, "status": md[n].get("status"), "error": md[n].get("error_message")}
                      for n in expected["models"] if n in md and md[n].get("status") not in (None, "Ready")]
        if not (missing or not_ready or missing_models or bad_models) or time.time() > deadline:
            return {"ok": not (missing or not_ready or missing_models or bad_models), "missing": missing,
                    "not_ready": not_ready, "missing_models": missing_models, "models_not_ready": bad_models}
        time.sleep(6)


def cmd_deploy(a):
    ctx = Ctx(a)
    pid = ctx.project_id()
    pod = find_pod(ctx.dir) or fail(f"no spicepod.yaml in {ctx.dir}")
    ok, counts, text = validate(ctx)
    if not ok:
        fail("spice validate failed", validate=text[-2000:])
    if sum(counts.get(k, 0) for k in ("datasets", "views", "catalogs", "models")) == 0:
        fail("the spicepod has no datasets, views, catalogs, or models: a deploy would prove nothing")
    status("Uploading spicepod.yaml as the project's stored spicepod ...")
    data, err = cli(ctx, "cloud", "project", "update", "--project", ctx.ref, "--spicepod", str(pod), "-o", "json")
    if err:
        fail("could not upload the spicepod", detail=err)
    spec = ((data or {}).get("config") or {}).get("spicepod") or {}
    replicas = ((data or {}).get("config") or {}).get("replicas") or 1
    expected = components(spec)
    notes = reachability(spec) + lint(spec, ctx.state.get("profile", "poc"))
    if replicas > 1 and ((spec.get("runtime") or {}).get("mcp")):
        notes.append({"level": "warn", "code": "mcp_replicas",
                      "message": f"{replicas} replicas: MCP sessions are held by one instance, so agents get 404 "
                                 "'Session not found' when a request lands on another. Use 1 replica for MCP clients "
                                 "(SQL and chat over HTTP are stateless and fine with several)."})
    notes = merge_notes(notes)
    if any(n["level"] == "error" for n in notes):
        fail("the spicepod has a configuration that fails on load", lint=notes)
    federated = {d.get("name") for d in spec.get("datasets") or [] if isinstance(d, dict) and not accelerated(d)}
    paused = get_project(ctx, pid).get("paused_at")
    before = {i["name"] for i in instances(ctx)}
    started = time.time()
    if paused:
        # Spice Cloud refuses deployments while a project is paused; resuming deploys the stored spicepod.
        status(f"The project is paused (since {paused}); resuming it deploys the uploaded spicepod ...")
        code, resumed = api(ctx, "POST", f"/v1/projects/{pid}/resume")
        if code != 200 or not isinstance(resumed, dict) or not resumed.get("deployment_id"):
            fail(f"could not resume the paused project (HTTP {code}: {error_text(resumed)})", paused_at=paused)
        dep = {"id": resumed["deployment_id"]}
    else:
        dep, err = cli(ctx, "cloud", "deploy", "--project", ctx.ref, "-o", "json")
        if err or not isinstance(dep, dict) or not dep.get("id"):
            schema = "Invalid spicepod configuration" in str(err or dep)
            fail("could not start the deployment", detail=err or dep, hints=[
                "Spice Cloud checks the stored spicepod against the published Spicepod schema when a deployment "
                "starts, which is stricter than `spice validate`. Known case: an embeddings or full_text_search "
                "row_id must be a list (`row_id: [id]`), not a single value."] if schema else [])
    dep_id = dep["id"]
    status(f"Deployment {dep_id} started; watching it (up to {a.timeout}s) ...")
    last, error_since, init_since, inst, lines, ds, captured = None, {}, {}, None, [], [], {}

    def stuck(reason, **extra):
        fail(reason, deployment=dep_id, instance=inst, **extra, problems=problem_lines(lines)[-12:],
             hints=hints_for(lines, ds), lint=notes,
             note="Spice Cloud keeps the deployment in_progress while the new instance is not ready, and the "
                  "previous version (if any) keeps serving. The new instance keeps running, holding its source "
                  "connections, until a new deployment supersedes it. Fix the cause and run deploy again. To stop "
                  "instead, `spice-launch.sh pause DIR` tears the runtime down (the previous version too) until the "
                  "next deploy.",
             next=f"spice-launch.sh deploy {ctx.dir}")

    sources = {d["name"]: d.get("from") for d in spec.get("datasets") or [] if isinstance(d, dict) and d.get("name")}
    polls, ready_checks, stale_record = 0, 0, None
    while True:
        code, d = api(ctx, "GET", f"/v1/projects/{pid}/deployments/{dep_id}")
        state = d.get("status") if isinstance(d, dict) else None
        if state != last:
            status(f"  deployment {dep_id}: {state}")
            last = state
        if state == "succeeded":
            break
        if state == "failed":
            retriable = str(d.get("error_code", "")).startswith("insufficient_")
            stuck(f"deployment failed: {d.get('error_code')}: {d.get('error_message')}", retriable=retriable)
        polls += 1
        if polls % 2 == 0:  # instance-level checks every ~20s
            current = instances(ctx)
            fresh = [i for i in current if i["name"] not in before]
            # The deployment record can stay in_progress after its instance is up (seen when deploying right after a
            # pause). Every instance new and ready, three checks running, and the endpoint serving this spicepod
            # is the rollout done.
            if fresh and len(fresh) == len(current) and all((i.get("spicedStatus") or {}).get("ready") for i in current):
                ready_checks += 1
                if ready_checks >= 3 and confirm_serving(*data_plane(ctx)[:2], expected, sources, timeout=30)["ok"]:
                    stale_record = state
                    break
            else:
                ready_checks = 0
            if fresh:
                inst = fresh[-1]["name"]
                lines = instance_logs(ctx, inst)
                ds = instance_datasets(ctx, inst)
                check = secrets_preflight(lines)
                if check:
                    captured[inst] = check
                if check and not check["resolved"]:
                    stuck("secrets referenced by the spicepod are not available in Spice Cloud",
                          unresolved=check["unresolved"])
                if any("Failed to load LLM" in l or "Failed to load embedding" in l for l in lines):
                    stuck("a model failed to load on the new instance")
                for row in ds:
                    if row.get("status") == "Error":
                        error_since.setdefault(row.get("name"), time.time())
                    else:
                        error_since.pop(row.get("name"), None)
                lasting = [r for r in ds if r.get("status") == "Error" and time.time() - error_since[r.get("name")] > 75]
                if lasting:
                    stuck("datasets stay in Error on the new instance",
                          datasets=[{"name": r.get("name"), "error": r.get("error_message")} for r in lasting])
                # A federated dataset only connects and reads its schema, so a long Initializing means it is waiting
                # on the source. Accelerated ones may legitimately load for many minutes.
                for row in ds:
                    if row.get("status") == "Initializing" and row.get("name") in federated:
                        init_since.setdefault(row.get("name"), time.time())
                    else:
                        init_since.pop(row.get("name"), None)
                stalled = [n for n, t in init_since.items() if time.time() - t > a.init_timeout]
                if stalled:
                    stuck(f"federated datasets are still Initializing after {a.init_timeout}s on the new instance",
                          datasets=[{"name": n, "status": "Initializing"} for n in stalled])
        if time.time() - started > a.timeout:
            stuck(f"the deployment did not finish within {a.timeout}s",
                  datasets=[{"name": r.get("name"), "status": r.get("status"), "error": r.get("error_message")} for r in ds])
        time.sleep(10)

    endpoint, key, project = data_plane(ctx)
    status("Deployment succeeded; confirming the new spicepod is what the endpoint serves ..." if not stale_record else
           f"Deployment {dep_id} still reads {stale_record}, but its instance is ready and serves this spicepod ...")
    serving = confirm_serving(endpoint, key, expected, sources)
    rows = instances(ctx)
    newest = rows[-1]["name"] if rows else None
    lines = instance_logs(ctx, newest) if newest else []
    secrets_check = secrets_preflight(lines) or captured.get(newest)
    refs = {k for k, v in references(pod.read_text()).items() if v & {"secrets", "env"}}
    for _ in range(10 if secrets_check is None and refs and newest else 0):
        # Right after a deploy, `spice cloud logs` can answer 404 for a minute or two (it still asks for the
        # replaced instance), so retry before calling the secret check unknown.
        time.sleep(15)
        lines = instance_logs(ctx, newest)
        secrets_check = secrets_preflight(lines)
        if secrets_check:
            break
    if secrets_check is None:
        secrets_check = {"resolved": True, "references": 0} if not refs else {
            "resolved": None, "references": len(refs),
            "note": "The runtime's startup secret check was not in the logs `spice cloud logs` returned. Every "
                    "dataset and model is Ready, which a missing secret would usually prevent; verify settles it."}
    seconds = round(time.time() - started)
    ctx.save(endpoint=endpoint, expected=expected, spec_sha=hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()[:12],
             last_deploy={"id": dep_id, "status": f"serving (record still {stale_record})" if stale_record else "succeeded",
                          "seconds": seconds, "at": now(),
                          "image_tag": (d or {}).get("image_tag"), "instance": newest})
    result = {"project": ctx.ref, "deployment": dep_id, "seconds": seconds, "endpoint": endpoint,
              "image_tag": (d or {}).get("image_tag"), "instance": newest, "serving": serving,
              "secrets": secrets_check, "lint": notes, "warnings": problem_lines(lines)[-10:]}
    if stale_record:
        result["deployment_record"] = {"status": stale_record, "note": (
            "Spice Cloud never marked this deployment succeeded, although its only instance is ready and serves this "
            "spicepod. Seen when deploying right after a pause; the next deployment supersedes it. Report it to "
            "Spice.ai if it persists.")}
    if not serving["ok"]:
        fail("the deployment succeeded, but the endpoint does not serve every component as Ready", **result,
             hints=hints_for(lines, serving["not_ready"]))
    emit({**result, "status": "deployed", "next": f"spice-launch.sh verify {ctx.dir}"})


# ---------------------------------------------------------------- verify


def percentile(values, p):
    ordered = sorted(values)
    return round(ordered[max(0, min(len(ordered) - 1, math.ceil(p / 100 * len(ordered)) - 1))], 1)


def mcp_check(endpoint, key, dataset):
    headers = {"X-API-Key": key, "Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "spice-launch", "version": "1"}}}
    code, text, hdrs = http("POST", endpoint + "/v1/mcp", json.dumps(init), headers, 30)
    if code == 403 and "Host header" in (text or ""):
        return {"ok": False, "error": "403 Host header is not allowed",
                "hint": "Add runtime.mcp.allowed_hosts: [\"*\"] to the spicepod and deploy again."}
    if code != 200:
        return {"ok": False, "error": f"initialize HTTP {code}: {(text or '')[:200]}"}
    sid = hdrs.get("mcp-session-id")
    session = {**headers, **({"Mcp-Session-Id": sid} if sid else {})}
    http("POST", endpoint + "/v1/mcp", json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}), session, 30)
    code, text, _ = http("POST", endpoint + "/v1/mcp", json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}), session, 30)
    listed = sse_json(text)
    tools = sorted({t.get("name") for t in ((listed or {}).get("result") or {}).get("tools", []) if isinstance(t, dict)})
    result = {"ok": "sql" in tools, "tools": [t for t in tools if "__" not in t], "session": bool(sid)}
    if dataset and "sql" in tools:
        call = {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": "sql", "arguments": {"query": f"SELECT * FROM {quote_ident(dataset)} LIMIT 1"}}}
        code, text, _ = http("POST", endpoint + "/v1/mcp", json.dumps(call), session, 60)
        answer = (sse_json(text) or {}).get("result") or {}
        content = "".join(c.get("text", "") for c in answer.get("content", []) if isinstance(c, dict))
        result["sql_tool"] = {"dataset": dataset, "is_error": answer.get("isError"), "returned": content[:160]}
        result["ok"] = result["ok"] and answer.get("isError") is False and content not in ("", '"[]"', "[]")
        # An agent keeps one session for a whole conversation; make sure it survives several calls.
        lost = 0
        for i in range(8):
            ping = {"jsonrpc": "2.0", "id": 10 + i, "method": "tools/call",
                    "params": {"name": "get_current_datetime", "arguments": {}}}
            code, _, _ = http("POST", endpoint + "/v1/mcp", json.dumps(ping), session, 30)
            lost += code == 404
        result["session_calls"] = {"calls": 8, "session_not_found": lost}
        if lost:
            result["ok"] = False
            result["hint"] = ("The MCP session was lost between calls (404 Session not found). With more than one "
                              "replica, requests in one session reach different instances, and sessions live in one "
                              "instance's memory. Run 1 replica for MCP clients and scale --cpu/--memory instead.")
    if sid:
        http("DELETE", endpoint + "/v1/mcp", None, session, 15)
    return result


def cmd_verify(a):
    ctx = Ctx(a)
    endpoint, key, project = data_plane(ctx)
    expected = ctx.state.get("expected") or components(((project.get("config") or {}).get("spicepod")) or {})
    spec = (project.get("config") or {}).get("spicepod") or {}
    checks = []

    def check(name, ok, warn=False, **detail):
        checks.append({"check": name, "ok": bool(ok), **({"level": "warn"} if warn else {}), **detail})
        status(f"  {'PASS' if ok else ('WARN' if warn else 'FAIL')} {name}")

    status(f"Verifying {ctx.ref} at {endpoint} ...")
    code, text, _ = dp(endpoint, key, "GET", "/v1/ready", accept="text/plain")
    check("ready", code == 200 and (text or "").strip() == "ready", response=(text or "").strip()[:80])
    datasets, models = served(endpoint, key)
    by_name = {d.get("name"): d for d in datasets if isinstance(d, dict)}
    specs = {d.get("name"): d for d in spec.get("datasets") or [] if isinstance(d, dict)}
    counted = None
    for name in expected["datasets"] + expected["views"]:
        row = by_name.get(name)
        if name in expected["datasets"] and (not row or row.get("status") != "Ready"):
            check(f"dataset {name} Ready", False, status=(row or {}).get("status", "missing"),
                  error=(row or {}).get("error_message"))
            continue
        code, rows = sql(endpoint, key, f"SELECT * FROM {quote_ident(name)} LIMIT 1", timeout=90)
        ok = code == 200 and isinstance(rows, list) and len(rows) > 0
        detail = {"columns": list(rows[0].keys())[:12]} if ok else {"http": code, "error": error_text(rows)}
        if ok and name in specs and accelerated(specs[name]):
            code, n = sql(endpoint, key, f"SELECT COUNT(*) AS n FROM {quote_ident(name)}", timeout=60)
            if code == 200 and isinstance(n, list) and n:
                detail["rows"] = n[0].get("n")
                counted = counted or (name, n[0].get("n"))
        check(f"{'view' if name in expected['views'] else 'dataset'} {name} returns rows", ok, **detail)
    query_ms = []
    for q in a.sql or []:
        t0 = time.perf_counter()
        code, rows = sql(endpoint, key, q, timeout=120, nocache=True)
        query_ms.append(round((time.perf_counter() - t0) * 1000, 1))
        check(f"query: {q[:70]}", code == 200 and isinstance(rows, list) and len(rows) > 0, ms=query_ms[-1],
              rows=len(rows) if isinstance(rows, list) else None, sample=rows[:5] if isinstance(rows, list) else error_text(rows))
    model_specs = {m.get("name"): m for m in spec.get("models") or [] if isinstance(m, dict)}
    if not a.no_model:
        served_models = {(m.get("id") or m.get("name")): m for m in models if isinstance(m, dict)}
        for name in expected["models"]:
            body = json.dumps({"model": name, "messages": [{"role": "user", "content": "Reply with the single word OK."}]})
            code, text, _ = dp(endpoint, key, "POST", "/v1/chat/completions", body, "application/json", timeout=120)
            reply = as_json(text)
            content = ((reply or {}).get("choices") or [{}])[0].get("message", {}).get("content") if isinstance(reply, dict) else None
            check(f"model {name} answers", code == 200 and bool(content), reply=(content or error_text(reply))[:120],
                  status=(served_models.get(name) or {}).get("status"))
            if code == 200:  # the OpenAI SDKs always ask for a compressed response
                code_gz, _, _ = dp(endpoint, key, "POST", "/v1/chat/completions", body, "application/json",
                                   timeout=120, extra={"Accept-Encoding": "gzip, deflate"})
                check(f"model {name} answers OpenAI SDK clients (Accept-Encoding: gzip)", code_gz == 200, warn=True,
                      http=code_gz, **({} if code_gz == 200 else {"hint": (
                          "Non-streaming /v1/chat/completions fails when the client asks for compression, which the "
                          "OpenAI SDKs do by default. Clients must send Accept-Encoding: identity (Python: "
                          "OpenAI(..., default_headers={'Accept-Encoding': 'identity'}); TypeScript: defaultHeaders) "
                          "or stream. AGENT-CONNECT.md includes this.")}))
            tools = str(((model_specs.get(name) or {}).get("params") or {}).get("tools") or "")
            if code == 200 and (a.ask or counted) and re.search(r"\b(auto|all|nsql|sql)\b", tools):
                question = a.ask or (f"Use the sql tool to count the rows in the table {counted[0]}. "
                                     "Reply with only the number.")
                body = json.dumps({"model": name, "messages": [{"role": "user", "content": question}]})
                code, text, _ = dp(endpoint, key, "POST", "/v1/chat/completions", body, "application/json", timeout=180)
                reply = as_json(text)
                content = ((reply or {}).get("choices") or [{}])[0].get("message", {}).get("content") if isinstance(reply, dict) else ""
                normal = lambda text: re.sub(r"[,\s_$]", "", text or "").lower()
                expected_text = a.expect if a.ask else str(counted[1])
                grounded = normal(expected_text) in normal(content) if expected_text else True
                check(f"model {name} answers from the data (tool use)", code == 200 and bool(content) and grounded,
                      question=question, reply=(content or error_text(reply))[:300], expected=expected_text,
                      **({"note": "No --expect given, so only a non-empty answer was checked."} if a.ask and not a.expect else {}))
        for name in expected["embeddings"]:
            body = json.dumps({"model": name, "input": "spice launch check"})
            code, text, _ = dp(endpoint, key, "POST", "/v1/embeddings", body, "application/json", timeout=90)
            vec = (((as_json(text) or {}).get("data") or [{}])[0].get("embedding") or []) if code == 200 else []
            check(f"embedding model {name} returns vectors", len(vec) > 0, dimensions=len(vec))
    if a.search:
        body = json.dumps({"text": a.search, "limit": 3})
        code, text, _ = dp(endpoint, key, "POST", "/v1/search", body, "application/json", timeout=90)
        results = (as_json(text) or {}).get("results", []) if code == 200 else []
        check(f"search: {a.search[:60]}", len(results) > 0, results=len(results),
              top=[{k: r.get(k) for k in ("dataset", "_score", "primary_key")} for r in results[:3]])
    if a.nsql:
        body = json.dumps({"query": a.nsql})
        code, text, _ = dp(endpoint, key, "POST", "/v1/nsql", body, "application/json", timeout=180)
        rows = as_json(text)
        check(f"nsql: {a.nsql[:60]}", code == 200 and isinstance(rows, list) and len(rows) > 0,
              sample=rows[:5] if isinstance(rows, list) else error_text(rows))
    if not a.no_mcp:
        first = next((n for n in expected["datasets"] if (by_name.get(n) or {}).get("status") == "Ready"), None)
        result = mcp_check(endpoint, key, first)
        check("MCP initialize, tools/list, and a sql tool call", result.pop("ok"), **result)
    latency = None
    probe = (a.sql or [None])[0] or (f"SELECT * FROM {quote_ident(counted[0] if counted else (expected['datasets'] or [''])[0])} LIMIT 10"
                                     if expected["datasets"] else None)
    samples = a.samples if (a.sql or counted) else min(a.samples, 10)  # federated sources pay per query
    if probe and samples > 0:
        status(f"Measuring latency over {samples} uncached queries ...")
        times, errors = [], 0
        for _ in range(samples):
            t0 = time.perf_counter()
            code, _ = sql(endpoint, key, probe, timeout=60, nocache=True)
            if code == 200:
                times.append((time.perf_counter() - t0) * 1000)
            else:
                errors += 1
        if times:
            latency = {"query": probe, "probe_source": "the first --sql" if a.sql else "the first accelerated dataset",
                       "slowest_sql_ms": max(query_ms) if query_ms else None,
                       "samples": len(times), "errors": errors, "p50_ms": percentile(times, 50),
                       "p95_ms": percentile(times, 95), "p99_ms": percentile(times, 99), "max_ms": round(max(times), 1),
                       "note": "Client-observed, including the network round trip from this machine."}
    failed = [c for c in checks if not c["ok"] and c.get("level") != "warn"]
    warnings = [c for c in checks if not c["ok"] and c.get("level") == "warn"]
    ctx.save(verify={"at": now(), "passed": len(checks) - len(failed) - len(warnings), "failed": len(failed),
                     "warnings": [c["check"] for c in warnings], "latency": latency,
                     "checks": [{k: c[k] for k in ("check", "ok")} for c in checks]})
    lines = [f"Verified {ctx.ref} at {endpoint}: {len(checks) - len(failed) - len(warnings)}/{len(checks)} checks "
             f"passed" + (f", {len(warnings)} warning(s)." if warnings else ".")]
    lines += [f"- {'PASS' if c['ok'] else ('WARN' if c.get('level') == 'warn' else 'FAIL')} {c['check']}" +
              (f" ({c['rows']} rows)" if c.get("rows") is not None else "") +
              (f" — {c['hint']}" if not c["ok"] and c.get("hint") else "") for c in checks]
    if latency:
        lines.append(f"- Latency over {latency['samples']} uncached runs of `{probe[:80]}`: p50 {latency['p50_ms']} ms, "
                     f"p99 {latency['p99_ms']} ms (client-observed)")
    result = {"project": ctx.ref, "endpoint": endpoint, "checks": checks, "latency": latency,
              "warnings": [{"check": c["check"], "hint": c.get("hint")} for c in warnings], "report": "\n".join(lines)}
    if failed:
        fail(f"{len(failed)} check(s) failed", **result)
    emit({**result, "status": "verified", "next": f"spice-launch.sh monitors {ctx.dir} --profile {ctx.state.get('profile', 'poc')}"})


# ---------------------------------------------------------------- monitors and fire drill

# (name, template, spec, severity by profile, meaning, first response, requirement)
MONITORS = [
    ("query failures", "query_failures", {"op": "GT", "window": "5m", "sustainSecs": 300},
     {"demo": "warn", "poc": "warn", "production": "critical"},
     "Queries are failing at a sustained rate (agents writing bad SQL fail occasionally; this fires on a pattern).",
     "spice cloud logs --project {project} --limit 200; look for the failing statements and dataset errors.", None),
    ("HTTP 5xx", "http_5xx", {"op": "GT", "threshold": 0, "window": "5m", "sustainSecs": 300},
     {"demo": "warn", "poc": "critical", "production": "critical"},
     "The runtime is returning server errors.",
     "spice cloud status --project {project}; then spice cloud logs --project {project} --limit 200.", None),
    ("model failures", "llm_failures", {"op": "GT", "threshold": 0, "window": "5m", "sustainSecs": 300},
     {"demo": "warn", "poc": "critical", "production": "critical"},
     "Calls to the model provider are failing (key revoked, quota, or provider outage).",
     "Check the provider status and key; rotate the secret and deploy again.", "models"),
    ("memory", "memory_working_set", {"op": "GT", "threshold": 85, "sustainSecs": 300},
     {"demo": "warn", "poc": "critical", "production": "critical"},
     "Memory is above 85% of the instance limit; accelerations or large queries risk an out-of-memory restart.",
     "spice cloud metrics --project {project}; federate or narrow large accelerations (refresh_sql). Raising "
     "--memory needs private compute (preflight: limits.resources).", None),
    ("query latency p99", "query_latency_p99", {"op": "GT", "window": "15m", "sustainSecs": 600},
     {"poc": "warn", "production": "warn"},
     "p99 query latency is well above the baseline measured at launch.",
     "Find slow statements in task history (SELECT * FROM runtime.task_history ORDER BY execution_duration_ms DESC); "
     "accelerate or index the hot dataset.", None),
    ("CPU", "container_cpu", {"op": "GT", "threshold": 90, "window": "15m", "sustainSecs": 900},
     {"production": "warn"},
     "CPU is above 90% of the limit for 15 minutes.",
     "spice cloud metrics --project {project}; find heavy statements in runtime.task_history. Raising --cpu needs "
     "private compute; with MCP clients add CPU, never replicas (MCP sessions break across replicas).", None),
    ("Flight failures", "flight_failures", {"op": "GT", "threshold": 0, "window": "5m", "sustainSecs": 300},
     {"production": "warn"},
     "Arrow Flight (SDK) requests are failing.", "spice cloud logs --project {project} --limit 200.", None),
    ("dataset refresh errors", "dataset_refresh_errors", {"op": "GT", "threshold": 0, "window": "15m", "sustainSecs": 0},
     {"poc": "warn", "production": "critical"},
     "An accelerated dataset failed to refresh; queries serve stale data.",
     "spice cloud datasets --project {project}; fix the source or its credentials.", "accelerated"),
    ("dataset errors", "dataset_status", {"op": "EQ", "threshold": 3, "sustainSecs": 300},
     {"production": "critical"},
     "A dataset is in Error.", "spice cloud datasets --project {project}; read its error.", None),
    ("instance health", "instance_health", {"op": "GT", "threshold": 0, "sustainSecs": 0},
     {"production": "critical"},
     "An instance failed health checks (crash, OOM kill, eviction).", "spice cloud status --project {project}.", None),
]


def targets_from(a):
    env = local_env(project_dir(a.dir))
    targets = []
    if a.email:
        targets.append({"type": "email", "emails": a.email, "recipientUserIds": []})
    if a.slack:
        targets.append({"type": "slack", "channelId": a.slack})
    if a.webhook:
        hook = {"type": "http", "url": a.webhook, "method": "POST"}
        if a.webhook_token_env:
            token = env.get(a.webhook_token_env)
            if not token:
                fail(f"--webhook-token-env {a.webhook_token_env} is not set")
            hook["token"] = token
        targets.append(hook)
    return targets


def list_alerts(ctx, pid):
    code, data = api(ctx, "GET", f"/v1/projects/{pid}/monitors")
    if code != 200:
        fail(f"could not list monitors (HTTP {code}: {error_text(data)})")
    return {m["name"].lower(): m for m in data.get("monitors", []) if isinstance(m, dict) and m.get("name")}


def alert_targets(monitor):
    targets = monitor.get("targets") or []
    if not targets and isinstance(monitor.get("target"), dict):
        targets = [monitor["target"]]
    return [{k: v for k, v in t.items() if k != "token"} for t in targets]


def verify_monitor(ctx, pid, alert_id, spec, targets):
    code, monitor = api(ctx, "GET", f"/v1/projects/{pid}/monitors/{alert_id}")
    if code != 200 or not isinstance(monitor, dict):
        return "could not read back the monitor"
    if monitor.get("status") != "active":
        return "monitor is disabled; use --enable-disabled only with the user's approval"
    if monitor.get("evaluation_unavailable_reason"):
        return f"monitor cannot evaluate: {monitor['evaluation_unavailable_reason']}"
    if any((monitor.get("spec") or {}).get(k) != v for k, v in spec.items()):
        return "saved condition does not match the requested condition"
    if targets:
        saved = {t.get("type"): t for t in alert_targets(monitor)}
        if set(saved) != {t["type"] for t in targets}:
            return "saved notification destination types do not match"
        for target in targets:
            actual = saved[target["type"]]
            for key, value in target.items():
                if key == "token":
                    continue
                observed = actual.get(key, "POST" if key == "method" else None)
                if key == "emails":
                    if {e.lower() for e in observed or []} != {e.lower() for e in value}:
                        return "saved email recipients do not match"
                elif key == "recipientUserIds":
                    if set(observed or []) != set(value):
                        return "saved member recipients do not match"
                elif observed != value:
                    return f"saved {target['type']} destination does not match"
    return None


def cmd_monitors(a):
    ctx = Ctx(a)
    pid = ctx.project_id()
    profile = a.profile or ctx.state.get("profile", "poc")
    project = get_project(ctx, pid)
    spec = (project.get("config") or {}).get("spicepod") or {}
    has_models = bool(spec.get("models"))
    has_accel = any(accelerated(d) for d in spec.get("datasets") or [] if isinstance(d, dict))
    measured = (ctx.state.get("verify") or {}).get("latency") or {}
    baseline, slowest = measured.get("p99_ms"), measured.get("slowest_sql_ms")
    basis = max(5 * (baseline or 0), 2 * (slowest or 0))
    latency_ms = a.latency_ms or (max(1000, int(math.ceil(basis / 100.0)) * 100) if basis else 5000)
    targets = targets_from(a)
    existing = list_alerts(ctx, pid)
    rows = []
    for key, template, base_spec, severities, meaning, response, needs in MONITORS:
        severity = severities.get(profile)
        if not severity or (needs == "models" and not has_models) or (needs == "accelerated" and not has_accel):
            continue
        body_spec = dict(base_spec, severity=severity)
        if template == "query_failures":
            body_spec["threshold"] = a.query_failure_rate
        if template == "query_latency_p99":
            body_spec["threshold"] = latency_ms
        name = PREFIX + key
        first = response.replace("{project}", ctx.ref)
        description = f"spice-launch ({profile}). {meaning} First response: {first}"[:500]
        row = {"name": name, "template": template, "condition": f"{body_spec['op']} {body_spec['threshold']}",
               "window": body_spec.get("window"), "sustain_secs": body_spec.get("sustainSecs"), "severity": severity,
               "meaning": meaning, "first_response": first}
        if a.dry_run:
            rows.append({**row, "status": "planned"})
            continue
        current = existing.get(name.lower())
        if current:
            expected_targets = targets or alert_targets(current)
            if current.get("template_id") != template:
                rows.append({**row, "id": current["id"], "status": "verification_failed",
                             "error": "Existing monitor has a different template; review it before changing its signal."})
                continue
            if current.get("status") == "disabled" and not a.enable_disabled:
                rows.append({**row, "id": current["id"], "status": "disabled",
                             "note": "Preserved disabled state; --enable-disabled requires the user's approval."})
                continue
            patch = {"spec": body_spec, **({"targets": targets} if targets else {}),
                     **({"status": "active"} if a.enable_disabled else {})}
            same = all(current.get("spec", {}).get(k) == v for k, v in body_spec.items()) and not targets and current.get("status") == "active"
            if same:
                err = verify_monitor(ctx, pid, current["id"], body_spec, expected_targets)
                rows.append({**row, "id": current["id"], "status": "verification_failed" if err else "unchanged",
                             **({"error": err} if err else {})})
                continue
            code, resp = api(ctx, "PATCH", f"/v1/projects/{pid}/monitors/{current['id']}", patch)
            if code != 200:
                rows.append({**row, "id": current["id"], "status": "update_failed",
                             "error": f"HTTP {code}: {error_text(resp)}"})
                continue
            err = verify_monitor(ctx, pid, current["id"], body_spec, expected_targets)
            rows.append({**row, "id": current["id"], "status": "verification_failed" if err else "updated",
                         **({"error": err} if err else {})})
            continue
        body = {"name": name, "description": description, "templateId": template, "spec": body_spec,
                **({"targets": targets} if targets else {})}
        code, resp = api(ctx, "POST", f"/v1/projects/{pid}/monitors", body)
        if code == 201:
            err = verify_monitor(ctx, pid, resp.get("id"), body_spec, targets)
            rows.append({**row, "id": resp.get("id"), "status": "verification_failed" if err else "created",
                         "targets": [t.get("type") for t in alert_targets(resp)],
                         **({"error": err} if err else {})})
        elif code == 404 and "unavailable" in error_text(resp):
            rows.append({**row, "status": "template_unavailable",
                          "note": "Check managed project kind, models, acceleration, and effective CPU limit."})
        else:
            rows.append({**row, "status": "create_failed", "error": f"HTTP {code}: {error_text(resp)}"})
    failed = [r for r in rows if r["status"] in ("create_failed", "update_failed", "verification_failed", "disabled")]
    live = [r for r in rows if r["status"] in ("created", "updated", "unchanged")]
    selected = {r["name"].lower() for r in rows}
    outside_profile = [{"id": m["id"], "name": m["name"], "status": m.get("status")}
                       for name, m in existing.items() if name.startswith(PREFIX) and name not in selected and name != DRILL.lower()]
    if not a.dry_run:
        ctx.save(profile=profile, monitors={r["name"]: r.get("id") for r in live},
                 monitor_targets=[{k: v for k, v in t.items() if k != "token"} for t in targets] or "preserved for existing alerts; default for new alerts",
                 monitor_rows=rows)
    result = {"project": ctx.ref, "profile": profile, "monitors": rows,
              "outside_profile": outside_profile,
              "targets": [{k: v for k, v in t.items() if k != "token"} for t in targets] or
                          "preserved for existing alerts; new alerts email the credential's user (org owner for machine credentials)",
              "latency_threshold_ms": latency_ms,
              "latency_basis": None if a.latency_ms or not basis else
                   f"max(5 x probe p99 {baseline} ms, 2 x slowest --sql {slowest} ms)"}
    if a.dry_run:
        emit({**result, "status": "planned"})
    if failed:
        fail("some monitors could not be created or updated", **result,
             hints=["Slack targets need Slack connected to the organization (HTTP 422).",
                     "Monitor updates need organization admin (403).",
                     "Disabled monitors stay disabled unless --enable-disabled is approved."])
    if not live:
        fail("no requested monitor is enabled and verified", **result)
    incomplete = any(r["status"] == "template_unavailable" for r in rows)
    emit({**result, "status": "monitoring_incomplete" if incomplete else "monitored",
          "next": f"spice-launch.sh fire-drill {ctx.dir}  (sends firing and recovery notifications)"})


def cmd_fire_drill(a):
    ctx = Ctx(a)
    pid = ctx.project_id()
    endpoint, key, _ = data_plane(ctx)
    existing = list_alerts(ctx, pid)
    launch_monitors = sorted((m for m in existing.values()
                              if m.get("name", "").startswith(PREFIX) and m["name"] != DRILL and m.get("status") == "active"),
                             key=lambda m: m["name"].lower() != (PREFIX + "query failures").lower())
    if not launch_monitors:
        fail("fire drill requires an enabled launch monitor; run monitors first")
    targets = next((alert_targets(m) for m in launch_monitors if alert_targets(m)), [])
    webhook = next((t for t in targets if t.get("type") == "http"), None)
    if webhook:
        if a.webhook_token_env:
            token = local_env(ctx.dir).get(a.webhook_token_env)
            if not token:
                fail(f"--webhook-token-env {a.webhook_token_env} is not set")
            webhook["token"] = token
        elif not a.webhook_no_token:
            fail("webhook tokens cannot be read back; supply --webhook-token-env VAR or --webhook-no-token for an unauthenticated destination",
                 hints=["The portal's Send test notification uses the saved token but checks delivery only."])
    stale = existing.get(DRILL.lower())
    if stale:
        code, resp = api(ctx, "DELETE", f"/v1/projects/{pid}/monitors/{stale['id']}")
        if code != 200:
            fail("could not clean up the previous drill monitor; retry DELETE on the same ID", id=stale["id"], detail=error_text(resp))
    drills = [("query_failures", {"op": "GT", "threshold": 0, "window": "1m", "sustainSecs": 0}, "failed queries"),
              ("memory_working_set", {"op": "GT", "threshold": 1, "sustainSecs": 0}, "memory above 1% (always true)")]
    for template_id, spec, trigger in drills:
        body = {"name": DRILL, "templateId": template_id,
                "description": "Temporary: tests signal evaluation and notification delivery. Recipients confirm arrival; spice-launch removes this monitor.",
                "spec": {**spec, "severity": "warn"}, **({"targets": targets} if targets else {})}
        code, mon = api(ctx, "POST", f"/v1/projects/{pid}/monitors", body)
        if code == 201:
            break
        if not (code == 404 and "unavailable" in error_text(mon)):
            fail(f"could not create the drill monitor (HTTP {code}: {error_text(mon)})")
    else:
        fail("no drill template is available to this organization", tried=[d[0] for d in drills])
    drill_id, started, fired, resolved = mon["id"], time.time(), None, None
    recovery_requested, recovery_error = False, None
    status(f"Drill monitor created ({template_id}: {trigger}); waiting for it to fire (up to {a.timeout}s) ...")
    try:
        while time.time() - started < a.timeout:
            if template_id == "query_failures" and not fired:
                sql(endpoint, key, "SELECT * FROM spice_launch_fire_drill_missing_table", timeout=30)
            code, m = api(ctx, "GET", f"/v1/projects/{pid}/monitors/{drill_id}")
            if code == 200 and isinstance(m, dict):
                fired = m.get("last_fired_at") or fired
                resolved = m.get("last_resolved_at")
            if template_id == "memory_working_set" and fired and not recovery_requested:
                code, response = api(ctx, "PATCH", f"/v1/projects/{pid}/monitors/{drill_id}",
                                     {"spec": {**spec, "threshold": 1000, "severity": "warn"}})
                if code != 200:
                    recovery_error = f"could not reset the temporary memory condition (HTTP {code}: {error_text(response)})"
                    break
                recovery_requested, resolved = True, None
            status(f"  t+{int(time.time() - started)}s last_fired_at={fired} last_resolved_at={resolved}")
            if fired and resolved and resolved >= fired:
                break
            time.sleep(20)
    finally:
        code, _ = api(ctx, "DELETE", f"/v1/projects/{pid}/monitors/{drill_id}")
        cleaned = code == 200
    notification_targets = [t.get("type") for t in targets] or ["email to the credential's user (default target)"]
    result = {"project": ctx.ref, "fired": bool(fired), "fired_at": fired, "seconds": round(time.time() - started),
              "template": template_id,
              "resolved": bool(fired and resolved and resolved >= fired), "resolved_at": resolved,
              "notification_targets": notification_targets, "delivery_confirmed": False, "drill_monitor_deleted": cleaned}
    ctx.save(fire_drill={**result, "at": now()})
    if not cleaned:
        fail("drill monitor cleanup failed; retry DELETE on the same ID", **result, id=drill_id)
    if recovery_error:
        fail(recovery_error, **result, id=drill_id,
             hints=["The memory fallback update requires org admin; close any downstream test incident manually."])
    if not fired:
        fail("the drill monitor did not fire in time", **result,
             hints=["Evaluations run every 60s; retry with a longer --timeout.",
                     "Monitors run only on managed projects with a live deployment."])
    if not result["resolved"]:
        fail("drill fired but recovery was not recorded; downstream incidents may need manual closure", **result, id=drill_id,
             hints=["Confirm recovery or close the test incident at each destination before handoff."])
    emit({**result, "status": "alert_fired", "note": "Ask the recipient to confirm arrival at every destination; firing alone does not prove delivery.",
          "next": f"spice-launch.sh handoff {ctx.dir}"})


# ---------------------------------------------------------------- hand-off docs, status, teardown


def md_table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c).replace("|", "\\|").replace("\n", " ") for c in row) + " |" for row in rows]
    return "\n".join(out)


GENERATED_BEGIN = "<!-- spice-launch:begin"
GENERATED_END = "<!-- spice-launch:end -->"


def write_generated(path, generated, tail=""):
    """Write generated text between markers; keep everything outside them, and never overwrite a hand-written file."""
    block = (f"{GENERATED_BEGIN} (regenerated by `spice-launch.sh handoff`; edit outside these markers) -->\n"
             f"{generated.strip()}\n{GENERATED_END}")
    if not path.exists():
        path.write_text(block + "\n" + tail)
        return "created"
    text = path.read_text()
    start, end = text.find(GENERATED_BEGIN), text.find(GENERATED_END)
    if start != -1 and end > start:
        path.write_text(text[:start] + block + text[end + len(GENERATED_END):])
        return "updated between markers"
    alternate = path.with_name(path.stem + ".generated.md")
    alternate.write_text(block + "\n")
    return f"kept (no markers, so hand-written); new version in {alternate.name}"


def cmd_handoff(a):
    ctx = Ctx(a)
    pid = ctx.project_id()
    project = get_project(ctx, pid)
    cfg = project.get("config") or {}
    spec = cfg.get("spicepod") or {}
    endpoint = (project.get("endpoint") or REGION_ENDPOINTS.get(cfg.get("region")) or "").rstrip("/")
    st = ctx.state
    deploy, verify, drill = st.get("last_deploy") or {}, st.get("verify") or {}, st.get("fire_drill") or {}
    monitors = list_alerts(ctx, pid)
    mon_rows = st.get("monitor_rows") or []
    lookup = {r["name"].lower(): r for r in mon_rows}
    portal = f"{PORTAL}/{ctx.org}/{ctx.name}"
    ds_rows = []
    for d in spec.get("datasets") or []:
        acc = d.get("acceleration") or {}
        refresh = acc.get("refresh_mode") or ("full" if accelerated(d) else "-")
        if acc.get("refresh_check_interval"):
            refresh += f" every {acc['refresh_check_interval']}"
        ds_rows.append([d.get("name"), str(d.get("from", "")).split("?")[0][:70],
                        (acc.get("engine") or "arrow") if accelerated(d) else "federated", refresh])
    model_rows = [[m.get("name"), m.get("from"), (m.get("params") or {}).get("tools", "-")] for m in spec.get("models") or []]
    emb_rows = [[e.get("name"), e.get("from")] for e in spec.get("embeddings") or []]
    alert_rows = []
    for name, m in sorted(monitors.items()):
        if not m.get("name", "").startswith(PREFIX) or m["name"] == DRILL:
            continue
        meta = lookup.get(name, {})
        s = m.get("spec") or {}
        window = "-" if m.get("template_id") in ("memory_working_set", "dataset_status", "instance_health") else s.get("window", "-")
        alert_rows.append([m["name"], m.get("template_id"), f"{s.get('op')} {s.get('threshold')}",
                           window, s.get("severity"), m.get("status"),
                           meta.get("meaning", ""), meta.get("first_response", "")])
    latency = verify.get("latency") or {}
    deployed = "\n\n".join(t for t in [
        md_table(['Dataset', 'Source', 'Acceleration', 'Refresh'], ds_rows) if ds_rows else "No datasets.",
        md_table(['Model', 'Provider', 'Tools'], model_rows) if model_rows else "",
        md_table(['Embedding model', 'Provider'], emb_rows) if emb_rows else ""] if t)
    runbook = f"""# {ctx.name} runbook

Spice.ai Cloud project `{ctx.ref}` ({st.get('profile', 'poc')} profile), created with spice-launch.

| | |
|---|---|
| Portal | {portal} |
| Data-plane endpoint | {endpoint} |
| Region / channel | {cfg.get('region')} / {cfg.get('update_channel')} |
| Replicas | {cfg.get('replicas')} |
| Last deployment | {deploy.get('id')} ({deploy.get('status')}, {deploy.get('image_tag')}, {deploy.get('at')}) |
| Last verification | {verify.get('at')}: {verify.get('passed')} passed, {verify.get('failed')} failed |
| Latency at launch | p50 {latency.get('p50_ms')} ms, p99 {latency.get('p99_ms')} ms over {latency.get('samples')} uncached queries (client-observed) |
| Alert fire drill | {('fired in ' + str(drill.get('seconds')) + ' s on ' + str(drill.get('at')) + '; recipient confirmation required') if drill.get('fired') else 'not run'} |

The spicepod in this directory is the source of truth: keep it in version control. Spice Cloud
deploys its stored copy, which `spice-launch.sh deploy` replaces on every deploy.

## What is deployed

{deployed}

Secrets are stored in Spice Cloud (project secrets, or org secrets linked to the project) and
referenced as `${{ secrets:NAME }}`; no value is in this directory's committed files.

## Alerts

{md_table(['Alert', 'Template', 'Fires when', 'Window', 'Severity', 'Status', 'Meaning', 'First response'], alert_rows) if alert_rows else 'No monitors yet: run `spice-launch.sh monitors`.'}

Thresholds use each template's unit: per-second rates for failures, milliseconds for latency,
refresh-error counts per dataset, and percent of the instance limit for memory and CPU. Change one by editing the flags and running
`spice-launch.sh monitors` again (it updates monitors in place), or in the portal.
Enabled configuration is not proof of current signal coverage. Check readiness and telemetry;
missing telemetry is not recovery. Review disabled, unavailable, and outside-profile monitors.

## Operate

Every task works with the `spice` CLI alone. `spice-launch.sh` (from the launch skill's
`scripts/` directory) wraps the multi-step ones and adds the checks noted.

| Task | Command |
|---|---|
| Health in one view | `spice cloud status --project {ctx.ref}` |
| Dataset load state | `spice cloud datasets --project {ctx.ref}` |
| Recent logs | `spice cloud logs --project {ctx.ref} --limit 200` |
| CPU and memory | `spice cloud metrics --project {ctx.ref} --window 5m` |
| Deploy a spicepod change | `spice cloud project update --project {ctx.ref} --spicepod spicepod.yaml`, then `spice cloud deploy --project {ctx.ref} --wait --timeout 10m`; or `spice-launch.sh deploy .`, which also diagnoses a stuck rollout and confirms the endpoint serves the new spicepod |
| Re-run the end-to-end checks | `spice-launch.sh verify .` (datasets, models, MCP, latency) |
| Roll back | check out the previous `spicepod.yaml` from version control and deploy it the same way |
| Rotate a source credential | `spice-launch.sh secrets . --set NAME` reads the new value from the environment or `.env.local` (`spice cloud secrets set NAME VALUE` works too, but puts the value in shell history), then deploy |
| Rotate API keys without downtime | `spice cloud api-keys --project {ctx.ref} --regenerate 2`, move clients to key 2, then `--regenerate 1` |
| Scale | `spice cloud project update --project {ctx.ref} --replicas N` (or `--cpu`, `--memory`), then deploy |
| Change an alert | `spice-launch.sh monitors .` with new flags updates monitors in place; or edit it in the portal |
| Tear down (demos, POCs) | `spice-launch.sh teardown . --yes`, or `spice cloud project delete {ctx.ref}` |

A deployment whose new instance never becomes ready stays `in_progress` while the previous
version keeps serving; `spice-launch.sh deploy` reports why (unresolved secret, dataset error,
model load failure, memory) instead of waiting it out.
"""
    chat_section = "" if not model_rows else f"""## OpenAI-compatible chat

Models: {', '.join(f'`{m[0]}`' for m in model_rows)}. The model answers with the tools its
spicepod `tools` param grants (e.g. `sql` over the datasets).

```python
import os
from openai import OpenAI

client = OpenAI(
    base_url="{endpoint}/v1",
    api_key=os.environ["SPICE_API_KEY"],
    # Non-streaming chat completions on Spice Cloud fail with 502 when the client asks for a
    # compressed response, which the SDK does by default. Streaming is unaffected.
    default_headers={{"Accept-Encoding": "identity"}},
)
reply = client.chat.completions.create(
    model="{model_rows[0][0]}",
    messages=[{{"role": "user", "content": "What datasets can you query?"}}],
)
print(reply.choices[0].message.content)
```

TypeScript: `new OpenAI({{ baseURL: "{endpoint}/v1", apiKey: process.env.SPICE_API_KEY,
defaultHeaders: {{ "Accept-Encoding": "identity" }} }})`.

"""
    agents = f"""# Connect agents and apps to {ctx.name}

Every client authenticates with a project API key. Get one with
`spice cloud api-keys --project {ctx.ref}` and export it; keys look like `<id>|<hex>`, so quote
them in shell and `.env` files:

```bash
export SPICE_API_KEY='<api key>'
```

Send it as `X-API-Key: $SPICE_API_KEY` or `Authorization: Bearer $SPICE_API_KEY`.

## MCP (agents)

Endpoint: `{endpoint}/v1/mcp` (Streamable HTTP). Agents get tools such as `sql`,
`list_datasets`, `table_schema`, and `search` over the datasets above.

Claude Code, for yourself in every directory (stores the key in your `~/.claude.json`):

```bash
claude mcp add --scope user --transport http {ctx.name} {endpoint}/v1/mcp --header "X-API-Key: $SPICE_API_KEY"
claude mcp list   # expect: {ctx.name}: {endpoint}/v1/mcp (HTTP) - ✔ Connected
```

Claude Code, shared through a committed `.mcp.json` (single quotes keep the key out of the file;
each user sets `SPICE_API_KEY` and approves the server on first use):

```bash
claude mcp add --scope project --transport http {ctx.name} {endpoint}/v1/mcp --header 'X-API-Key: ${{SPICE_API_KEY}}'
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.{ctx.name.replace('-', '_')}]
url = "{endpoint}/v1/mcp"
env_http_headers = {{ "X-API-Key" = "SPICE_API_KEY" }}
```

Cursor (`.cursor/mcp.json`):

```json
{{"mcpServers": {{"{ctx.name}": {{"url": "{endpoint}/v1/mcp", "headers": {{"X-API-Key": "${{env:SPICE_API_KEY}}"}}}}}}}}
```

{chat_section}
## SQL over HTTP

```bash
curl -s {endpoint}/v1/sql -H "X-API-Key: $SPICE_API_KEY" -H 'Content-Type: text/plain' \\
  -d 'SELECT * FROM {quote_ident(ds_rows[0][0]) if ds_rows else 'my_dataset'} LIMIT 5'
```

The body is raw SQL. A JSON body needs `"parameters"` (`[]` when unused) and exactly
`Content-Type: application/json`.
"""
    notes_stub = ("\n## Scenario notes\n\nStand-in or pending sources and how to swap them, agent questions that work, "
                  "data caveats, and what the user still owns.\n")
    written = {"RUNBOOK.md": write_generated(ctx.dir / "RUNBOOK.md", runbook, notes_stub),
               "AGENT-CONNECT.md": write_generated(ctx.dir / "AGENT-CONNECT.md", agents)}
    emit({"status": "written", "files": written,
          "note": "Only the text between the spice-launch markers is regenerated. Write the Scenario notes (stand-in "
                  "or pending sources, questions that work, what the user still owns) outside the markers."})


def cmd_pause(a):
    ctx = Ctx(a)
    pid = ctx.project_id()
    code, data = api(ctx, "POST", f"/v1/projects/{pid}/pause")
    if code == 409:
        emit({"status": "paused", "project": ctx.ref, "paused_at": (data or {}).get("paused_at"), "note": "Already paused."})
    if code != 200:
        fail(f"could not pause {ctx.ref} (HTTP {code}: {error_text(data)})")
    ctx.save(paused_at=data.get("paused_at"))
    emit({"status": "paused", "project": ctx.ref, "paused_at": data.get("paused_at"),
          "note": "The runtime is torn down and stops using its sources; configuration, secrets, keys, and monitors are "
                  "kept. Queries fail until the next deploy, which resumes the project.",
          "next": f"spice-launch.sh deploy {ctx.dir}"})


def cmd_status(a):
    ctx = Ctx(a)
    pid = ctx.project_id()
    paused = get_project(ctx, pid).get("paused_at")
    if paused:
        emit({"project": ctx.ref, "healthy": False, "paused_at": paused,
              "note": "The project is paused: no runtime is running.", "next": f"spice-launch.sh deploy {ctx.dir}"})
    st = cloud_status(ctx)
    latest = st.get("latest_deployment") or {}
    rows = instances(ctx)
    newest = rows[-1]["name"] if rows else None
    lines = instance_logs(ctx, newest, limit=200) if newest else []
    alerts = [{"name": m.get("name"), "status": m.get("status"), "last_fired_at": m.get("last_fired_at")}
              for m in list_alerts(ctx, pid).values()]
    healthy = latest.get("status") == "succeeded" and all((i.get("spicedStatus") or {}).get("ready") for i in rows)
    emit({"project": ctx.ref, "healthy": healthy,
          "deployment": {k: latest.get(k) for k in ("id", "status", "image_tag", "error_message")},
          "instances": [{"name": i["name"], "phase": i.get("phase"), **(i.get("spicedStatus") or {})} for i in rows],
          "datasets_unhealthy": st.get("datasets_unhealthy"), "runtime_error": st.get("runtime_error"),
          "alerts": alerts, "recent_problems": problem_lines(lines)[-10:], "hints": hints_for(lines)})


def cmd_teardown(a):
    ctx = Ctx(a)
    if not a.yes:
        fail("teardown deletes the project and its monitors: re-run with --yes once the user confirms",
             project=ctx.ref, created_by_launch=ctx.state.get("created_by_launch", False))
    pid = ctx.project_id()
    deleted = []
    for m in list_alerts(ctx, pid).values():
        if m.get("name", "").startswith(PREFIX):
            code, _ = api(ctx, "DELETE", f"/v1/projects/{pid}/monitors/{m['id']}")
            deleted.append({"monitor": m["name"], "deleted": code == 200})
    project_deleted = False
    if not a.keep_project:
        if not ctx.state.get("created_by_launch"):
            fail(f"{ctx.ref} was not created by spice-launch, so it is left in place", monitors=deleted,
                 hint=f"If the user wants it gone: spice cloud project delete {ctx.ref}")
        data, err = cli(ctx, "cloud", "project", "delete", ctx.ref, "-y", "-o", "json")
        if err:
            fail("could not delete the project", detail=err, monitors=deleted)
        project_deleted = True
    ctx.save(torn_down_at=now(), project_deleted=project_deleted)
    emit({"status": "torn_down", "project": ctx.ref, "project_deleted": project_deleted, "monitors": deleted})


def main():
    parser = argparse.ArgumentParser(prog="spice-launch.sh", description="Launch a spicepod on Spice.ai Cloud")
    sub = parser.add_subparsers(dest="command", required=True)

    def add(name, func, project=False, help_text=None):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("dir", nargs="?", default=".")
        p.add_argument("--project", required=project, help="ORG/NAME")
        p.set_defaults(func=func)
        return p

    p = add("login", cmd_login, help_text="sign in to Spice Cloud with a device code (sign-up included)")
    p.add_argument("--wait", action="store_true", help="wait for the user to approve the code from a previous login")
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument("--force", action="store_true", help="sign in again even if a working credential exists")
    p.add_argument("--store", choices=["keychain", "env"], help="where the CLI saves the credential "
                   "(default: keychain on macOS, else .env in DIR)")
    add("preflight", cmd_preflight, help_text="check the CLI, Cloud credential, org, limits, and spicepod")
    p = add("local", cmd_local, help_text="smoke-run the spicepod on a local runtime, then stop it")
    p.add_argument("--timeout", type=int, default=120)
    p.add_argument("--anyway", action="store_true", help=argparse.SUPPRESS)  # older instructions; local always runs
    p = add("create", cmd_create, project=True, help_text="create or fork the managed project")
    p.add_argument("--region", default="us-east-1", choices=sorted(REGION_ENDPOINTS))
    p.add_argument("--base", help="ORG/BASE project to fork, inheriting its secrets and linked org secrets")
    p.add_argument("--profile", choices=["demo", "poc", "production"])
    p.add_argument("--replicas", type=int)
    p.add_argument("--channel", default="stable", choices=["stable", "preview", "nightly"])
    p.add_argument("--description")
    p = add("secrets", cmd_secrets, help_text="store the spicepod's secrets as project secrets")
    p.add_argument("--set", action="append", help="push NAME from the local environment even if it exists")
    p = add("deploy", cmd_deploy, help_text="upload the spicepod, deploy, and confirm the new version serves")
    p.add_argument("--timeout", type=int, default=600)
    p.add_argument("--init-timeout", type=int, default=180,
                   help="seconds a federated dataset may stay Initializing on the new instance")
    p = add("verify", cmd_verify, help_text="prove datasets, models, MCP, and latency end to end")
    p.add_argument("--sql", action="append")
    p.add_argument("--ask")
    p.add_argument("--expect", help="text the --ask answer must contain (digits compared without separators)")
    p.add_argument("--search")
    p.add_argument("--nsql")
    p.add_argument("--samples", type=int, default=50)
    p.add_argument("--no-model", action="store_true")
    p.add_argument("--no-mcp", action="store_true")
    p = add("monitors", cmd_monitors, help_text="create or update the profile's monitors")
    p.add_argument("--profile", choices=["demo", "poc", "production"])
    p.add_argument("--email", action="append")
    p.add_argument("--slack", help="Slack channel ID (C...), with Slack connected to the org")
    p.add_argument("--webhook", help="public HTTPS URL that receives alert POSTs")
    p.add_argument("--webhook-token-env", help="variable holding the webhook's bearer token")
    p.add_argument("--latency-ms", type=int)
    p.add_argument("--query-failure-rate", type=float, default=0.05, help="failed queries per second (default 0.05 = 3/min)")
    p.add_argument("--enable-disabled", action="store_true", help="re-enable selected launch monitors only with the user's approval")
    p.add_argument("--dry-run", action="store_true")
    p = add("fire-drill", cmd_fire_drill, help_text="record drill firing and recovery, then remove it; recipients confirm delivery")
    p.add_argument("--timeout", type=int, default=420)
    group = p.add_mutually_exclusive_group()
    group.add_argument("--webhook-token-env", help="variable holding the saved webhook's bearer token (not printed)")
    group.add_argument("--webhook-no-token", action="store_true", help="confirm the saved webhook requires no bearer token")
    add("handoff", cmd_handoff, help_text="write RUNBOOK.md and AGENT-CONNECT.md")
    add("status", cmd_status, help_text="one-shot health: deployment, instances, datasets, alerts, problems")
    add("pause", cmd_pause, help_text="tear the runtime down, keeping the project; the next deploy resumes it")
    p = add("teardown", cmd_teardown, help_text="delete the launch monitors and the project launch created")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--keep-project", action="store_true")

    args = parser.parse_args()
    args.func(args)


main()
PY
