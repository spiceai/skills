#!/bin/bash
set -e

# Find, fetch, and inspect Spice.ai cookbook recipes (https://github.com/spiceai/cookbook).
#
# Usage:
#   cookbook.sh fetch [--dir DIR] [--pr NUMBER | --ref BRANCH] [--no-update]
#   cookbook.sh list [--dir DIR] [TERM...]
#   cookbook.sh inspect RECIPE [--dir DIR]
#
#   fetch    Reuse or clone the cookbook checkout and bring it up to date, or check
#            out a pull request or branch. Never discards changes to tracked files.
#   list     List recipes from the cookbook README index plus unlisted recipe
#            directories. Every TERM must match the path, title, category, or
#            description (case-insensitive).
#   inspect  Report what a recipe needs and what is already in place: runtime
#            version, Docker, secrets, tools, and ports. Secret values are never
#            printed, only whether each one is set, empty, or a placeholder.
#
# The checkout is found in this order: --dir, $SPICE_COOKBOOK_DIR, the current
# directory or a parent, ./cookbook, ~/spice-cookbook, ~/cookbook. fetch clones
# into --dir, $SPICE_COOKBOOK_DIR, or ~/spice-cookbook when none exists.
#
# Status goes to stderr; results go to stdout as JSON.

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by cookbook.sh" >&2
  exit 1
fi

exec python3 - "$@" <<'PY'
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path

REPO_URL = "https://github.com/spiceai/cookbook.git"
DEFAULT_BRANCH = "trunk"
DEFAULT_DIR = Path.home() / "spice-cookbook"
SKIP_DIRS = {"node_modules", ".git", ".venv", "venv", "target", "vendor", "bin", "obj", ".spice", "__pycache__"}

# Connectors that need a server. A recipe with a compose file usually starts one;
# otherwise the user brings their own.
SERVICE_CONNECTORS = {
    "postgres", "pg", "mysql", "mssql", "mongodb", "clickhouse", "kafka", "debezium", "dremio",
    "oracle", "scylladb", "elasticsearch", "ftp", "sftp", "smb", "imap", "spark", "odbc",
    "unity_catalog", "iceberg",
}
# Connectors that need an account the user owns.
ACCOUNT_CONNECTORS = {
    "databricks", "snowflake", "dynamodb", "glue", "sharepoint", "spice.ai", "spiceai", "abfs",
    "gs", "gcs", "bigquery", "delta_lake", "redshift",
}
PUBLIC_BUCKETS = ("spiceai-public-datasets", "spiceai-demo-datasets")
KNOWN_TOOLS = [
    "docker", "docker-compose", "make", "python", "python3", "pip", "pip3", "uv", "uvx", "pipx",
    "node", "npm", "npx", "yarn", "pnpm", "go", "cargo", "java", "javac", "mvn", "gradle", "sbt",
    "dotnet", "duckdb", "psql", "mysql", "sqlite3", "websocat", "jq", "kubectl", "helm", "kind",
    "minikube", "aws", "az", "gcloud", "terraform", "wget", "openssl", "grpcurl", "brew", "gh",
]
PLACEHOLDER_RE = re.compile(
    r"^$|^<.*>$|your|_here\b|\bhere$|xxx|\.\.\.|changeme|replace|placeholder|example|\btodo\b|add .*key",
    re.I,
)


def status(msg):
    print(msg, file=sys.stderr)


def emit(obj):
    print(json.dumps(obj, indent=2))


def fail(msg, **extra):
    status(f"Error: {msg}")
    emit({"error": msg, **extra})
    sys.exit(1)


def run(cmd, cwd=None, timeout=60):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as err:
        return subprocess.CompletedProcess(cmd, 1, "", str(err))


def git(args, cwd, check=True, timeout=180):
    r = run(["git", *args], cwd=cwd, timeout=timeout)
    if check and r.returncode != 0:
        fail(f"git {' '.join(args)} failed: {r.stderr.strip()}", dir=str(cwd))
    return r.stdout.strip()


# ---------------------------------------------------------------- checkout


def is_cookbook(path):
    readme = Path(path) / "README.md"
    if not readme.is_file():
        return False
    try:
        return "Spice.ai OSS Cookbook" in readme.read_text(errors="ignore")[:500]
    except OSError:
        return False


def find_checkout(explicit):
    """Return (path, how) for an existing checkout, or (None, clone_target)."""
    for value, how in ((explicit, "--dir"), (os.environ.get("SPICE_COOKBOOK_DIR"), "SPICE_COOKBOOK_DIR")):
        if value:
            path = Path(value).expanduser().resolve()
            return (path, how) if is_cookbook(path) else (None, path)
    cwd = Path.cwd().resolve()
    for path in (cwd, *cwd.parents):
        if is_cookbook(path):
            return path, "current directory"
    for path, how in ((cwd / "cookbook", "./cookbook"), (DEFAULT_DIR, "~/spice-cookbook"),
                      (Path.home() / "cookbook", "~/cookbook")):
        if is_cookbook(path):
            return path.resolve(), how
    return None, DEFAULT_DIR


def require_checkout(explicit):
    path, how = find_checkout(explicit)
    if path is None:
        fail(f"no cookbook checkout found (looked for {how}); run `cookbook.sh fetch` first")
    return path


def tracked_changes(path):
    # Porcelain lines are "XY path"; X may be a space, so don't strip the output.
    out = run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=path).stdout
    return [line[3:] for line in out.splitlines() if line.strip()]


def head_info(path):
    fmt = git(["log", "-1", "--format=%h%x09%cs%x09%s"], path, check=False).split("\t")
    branch = git(["rev-parse", "--abbrev-ref", "HEAD"], path, check=False)
    return {
        "branch": None if branch == "HEAD" else branch,
        "commit": fmt[0] if fmt else None,
        "commit_date": fmt[1] if len(fmt) > 1 else None,
        "commit_subject": fmt[2] if len(fmt) > 2 else None,
    }


def fast_forward(path, notes):
    """Fetch the default branch and fast-forward to it. Returns the action taken."""
    before = git(["rev-parse", "HEAD"], path)
    status(f"Fetching {DEFAULT_BRANCH} ...")
    git(["fetch", "origin", DEFAULT_BRANCH], path)
    r = run(["git", "merge", "--ff-only", "FETCH_HEAD"], cwd=path)
    if r.returncode != 0:
        notes.append(f"local {DEFAULT_BRANCH} has diverged from origin; left it as is")
        return "kept"
    return "up-to-date" if git(["rev-parse", "HEAD"], path) == before else "updated"


def cmd_fetch(args):
    if args.pr and args.ref:
        fail("pass --pr or --ref, not both")
    path, how = find_checkout(args.dir)
    notes = []
    action = "reused"
    if path is None:
        target = how
        if target.exists() and any(target.iterdir()):
            fail(f"{target} exists and is not a cookbook checkout; pass --dir to pick another location")
        existing = next(p for p in target.parents if p.exists())
        enclosing = run(["git", "rev-parse", "--show-toplevel"], cwd=existing)
        if enclosing.returncode == 0:
            notes.append(f"{target} is inside the git repository {enclosing.stdout.strip()}")
        target.parent.mkdir(parents=True, exist_ok=True)
        status(f"Cloning {REPO_URL} into {target} ...")
        git(["clone", "--depth", "1", "--branch", DEFAULT_BRANCH, REPO_URL, str(target)], target.parent, timeout=600)
        path, how, action = target, "new clone", "cloned"
    else:
        status(f"Using the cookbook checkout at {path} (found via {how})")

    dirty = tracked_changes(path)
    branch = head_info(path)["branch"]
    wants_default = args.ref == DEFAULT_BRANCH

    if args.pr or (args.ref and not wants_default):
        if dirty:
            fail("the checkout has changes to tracked files; commit, stash, or revert them first",
                 dir=str(path), dirty=dirty)
        refspec = f"pull/{args.pr}/head" if args.pr else args.ref
        status(f"Fetching {refspec} ...")
        git(["fetch", "--depth", "1", "origin", refspec], path)
        git(["checkout", "--quiet", "--detach", "FETCH_HEAD"], path)
        action = "checked-out"
        notes.append(f"detached at {refspec}; `cookbook.sh fetch --ref {DEFAULT_BRANCH}` returns to {DEFAULT_BRANCH}")
    elif args.no_update or action == "cloned":
        pass
    elif dirty:
        notes.append("tracked files have local changes, so the checkout was not updated")
        action = "kept"
    elif branch == DEFAULT_BRANCH:
        action = fast_forward(path, notes)
    elif branch is None or wants_default:
        # Detached (e.g. an earlier --pr checkout) or asked for the default branch.
        if run(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{DEFAULT_BRANCH}"], cwd=path).returncode == 0:
            git(["checkout", "--quiet", DEFAULT_BRANCH], path)
        else:
            git(["fetch", "--depth", "1", "origin", DEFAULT_BRANCH], path)
            git(["checkout", "--quiet", "-B", DEFAULT_BRANCH, "FETCH_HEAD"], path)
        action = fast_forward(path, notes)
    else:
        notes.append(f"on branch {branch}, left as is; pass --ref {DEFAULT_BRANCH} to switch")
        action = "kept"

    emit({"dir": str(path), "found_via": how, "action": action, **head_info(path),
          "pull_request": args.pr, "dirty": tracked_changes(path), "notes": notes})


# ---------------------------------------------------------------- recipes


def read(path):
    try:
        return Path(path).read_text(errors="ignore")
    except OSError:
        return ""


def title_of(readme_text, fallback):
    m = re.search(r"^#\s+(.+?)\s*$", readme_text, re.M)
    return m.group(1).strip() if m else fallback


def min_version(readme_text):
    m = re.search(r"Works with\s+`?(v?\d+(?:\.\d+){0,2}\+?)`?", readme_text[:2000])
    return m.group(1) if m else None


def deprecated_in(readme_text):
    m = re.search(r"Deprecated in\s+`?(v?\d+(?:\.\d+){0,2}\+?)`?", readme_text[:2000])
    return m.group(1) if m else None


def walk_dirs(root):
    for dirpath, dirnames, _ in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.startswith("."))
        yield Path(dirpath)


def spicepods_in(path):
    return sorted(p for p in Path(path).glob("spicepod*.y*ml") if p.is_file())


def recipe_dirs(root):
    """Directories with a README that is a recipe: it names a version or ships a spicepod."""
    found = []
    for d in walk_dirs(root):
        if d == root or d.name == "data":
            continue
        readme = d / "README.md"
        if readme.is_file():
            text = read(readme)
            if min_version(text) or spicepods_in(d) or "spice run" in text:
                found.append(d)
    return found


def readme_index(root):
    """Parse the cookbook README's recipe list into {path: {title, categories, description}}."""
    index = {}
    category = None
    link = re.compile(r"^\s*[-*]\s+\[([^\]]+)\]\(\.?/?([^)#\s]+?)(?:/README\.md)?/?\)\s*(?:[-–—:]\s*(.*))?$")
    for line in read(root / "README.md").splitlines():
        h = re.match(r"^#{2,4}\s+(.+?)\s*$", line)
        if h:
            category = re.split(r"\s+-\s+", h.group(1))[0].strip()
            continue
        m = link.match(line)
        if not m:
            continue
        title, rel, desc = m.group(1).strip(), m.group(2).strip("/"), (m.group(3) or "").strip()
        entry = index.setdefault(rel, {"title": title, "categories": [], "description": desc})
        if category and category not in entry["categories"]:
            entry["categories"].append(category)
        if desc and not entry["description"]:
            entry["description"] = desc
    return index


def recipe_files(d):
    """Directories holding the recipe's spicepods: d and subdirectories that aren't nested recipes."""
    run_dirs = []
    for dirpath, dirnames, _ in os.walk(d):
        dirnames[:] = sorted(n for n in dirnames if n not in SKIP_DIRS and not n.startswith(".")
                             and not (Path(dirpath) / n / "README.md").is_file())
        if spicepods_in(dirpath):
            run_dirs.append(Path(dirpath))
    return run_dirs


def pods_text_of(run_dirs, readme_text):
    """Spicepod text: the recipe's spicepod files, or the README's YAML when the README writes the spicepod."""
    if run_dirs:
        return "".join(read(p) for rd in run_dirs for p in spicepods_in(rd))
    blocks = re.findall(r"```[\w-]*[^\n]*\n(.*?)```", readme_text, re.S)
    return "\n".join(b for b in blocks if re.search(r"^\s*-?\s*from:", b, re.M))


def connectors_of(pod_text):
    names = set()
    s3_private = False
    for m in re.finditer(r"^\s*-?\s*from:\s*['\"]?([^\s'\"#]+)", pod_text, re.M):
        value = m.group(1)
        scheme = re.split(r"[:/]", value, maxsplit=1)[0].lower()
        names.add(scheme)
        if scheme == "s3" and not any(b in value for b in PUBLIC_BUCKETS):
            s3_private = True
    return names, s3_private


def compose_files(d):
    return sorted(p.name for p in d.iterdir()
                  if p.name in ("compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"))


def readme_commands(readme_text):
    tools = []
    for lang, body in re.findall(r"```([\w-]*)[^\n]*\n(.*?)```", readme_text, re.S):
        if lang.lower() not in ("", "bash", "sh", "shell", "console", "zsh", "terminal", "shellsession"):
            continue
        for line in body.splitlines():
            line = re.sub(r"^\s*(?:\$|>|#)\s+", "", line.strip())
            for part in re.split(r"&&|\|\||;|\|", line):
                words = [w for w in part.strip().split() if not re.match(r"^[A-Z_][A-Z0-9_]*=", w) and w != "sudo"]
                if words and words[0] in KNOWN_TOOLS and words[0] not in tools:
                    tools.append(words[0])
    return tools


def needs_of(d, readme_text, pods_text, env_keys_needed):
    needs = []
    connectors, s3_private = connectors_of(pods_text)
    has_compose = bool(compose_files(d)) or re.search(r"docker[ -]compose|docker run", readme_text)
    if has_compose:
        needs.append("docker")
    if env_keys_needed:
        needs.append("keys")
    if connectors & ACCOUNT_CONNECTORS or s3_private:
        needs.append("cloud-account")
    if connectors & SERVICE_CONNECTORS and not has_compose:
        needs.append("own-server")
    tools = readme_commands(readme_text)
    if set(tools) & {"kubectl", "helm", "kind", "minikube"}:
        needs.append("kubernetes")
    if set(tools) & {"python", "python3", "pip", "pip3", "uv", "node", "npm", "yarn", "pnpm", "go", "cargo",
                     "java", "mvn", "gradle", "sbt", "dotnet"}:
        needs.append("toolchain")
    if deprecated_in(readme_text):
        needs.append("v1-only")
    return needs


def secret_refs(pods_text):
    refs = {}
    for store, key in re.findall(r"\$\{\s*(secrets|env)\s*:\s*([A-Za-z0-9_]+)\s*\}", pods_text):
        refs.setdefault(key, f"${{{store}:{key}}}")
    return refs


def parse_env(path):
    values = {}
    if not path:
        return values
    for raw in read(path).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        values.setdefault(key, value)
    return values


def nearest(start, name):
    """Like the runtime's dotenv loader: the working directory, then each parent."""
    for d in (start, *start.parents):
        if (d / name).is_file():
            return d / name
    return None


def is_placeholder(value):
    return bool(PLACEHOLDER_RE.search(value.strip()))


def unset_keys(d, pods_text):
    """Secrets that neither the shell nor a non-placeholder .env value provides (for `list`)."""
    env = {**parse_env(d / ".env"), **parse_env(d / ".env.local")}
    missing = []
    for key in secret_refs(pods_text):
        names = accepted_names(key)
        if any(n in os.environ for n in names):
            continue
        if any(n in env and not is_placeholder(env[n]) for n in names):
            continue
        missing.append(key)
    return missing


def accepted_names(key):
    """The env secret store tries SPICE_<key>, <key>, then both uppercased."""
    names = []
    for n in (f"SPICE_{key}", key, f"SPICE_{key.upper()}", key.upper()):
        if n not in names and not n.upper().startswith("SPICE_SPICE_"):
            names.append(n)
    return names


# ---------------------------------------------------------------- environment


def parse_version(text):
    m = re.search(r"v?(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    return tuple(int(x or 0) for x in m.groups()) if m else None


def spice_versions():
    exe = shutil.which("spice")
    info = {"installed": False, "on_path": bool(exe)}
    if not exe and (Path.home() / ".spice/bin/spice").exists():
        exe = str(Path.home() / ".spice/bin/spice")
    if not exe:
        return info
    out = run([exe, "version"], timeout=30)
    text = out.stdout + out.stderr
    cli = re.search(r"CLI version:\s*(\S+)", text)
    rt = re.search(r"Runtime version:\s*([^\n]+)", text)
    info.update(installed=True, cli=cli.group(1) if cli else None,
                runtime=rt.group(1).strip() if rt else None)
    if info["runtime"] and not parse_version(info["runtime"]):
        info["runtime_installed"] = False
    return info


def env_precedence(runtime_version):
    """Highest first. v2.1.x let .env override .env.local and exported variables (fixed in v2.2.0)."""
    if runtime_version and runtime_version[:2] == (2, 1):
        return [".env", ".env.local", "shell"]
    return ["shell", ".env.local", ".env"]


def docker_state():
    if not shutil.which("docker"):
        return {"installed": False, "running": False, "compose": None, "compose_standalone": False}
    r = run(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=15)
    compose = run(["docker", "compose", "version", "--short"], timeout=15)
    return {"installed": True, "running": r.returncode == 0,
            "compose": compose.stdout.strip() if compose.returncode == 0 else None,
            "compose_standalone": bool(shutil.which("docker-compose")),
            "error": None if r.returncode == 0 else (r.stderr.strip().splitlines() or [""])[-1][:200]}


def port_owner(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.3):
            pass
    except OSError:
        return None
    if shutil.which("lsof"):
        r = run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fpc"], timeout=10)
        pid = re.search(r"^p(\d+)", r.stdout, re.M)
        cmd = re.search(r"^c(.+)$", r.stdout, re.M)
        if cmd:
            return f"{cmd.group(1)} (pid {pid.group(1)})" if pid else cmd.group(1)
    return "unknown process"


def compose_ports(d):
    ports = set()
    for name in compose_files(d):
        for m in re.finditer(r"^\s*-\s*[\"']?(?:[\d.]+:)?(\d+):\d+", read(d / name), re.M):
            ports.add(int(m.group(1)))
    return sorted(ports)


def is_tracked(root, path):
    return run(["git", "ls-files", "--error-unmatch", str(path)], cwd=root).returncode == 0


def rel_or_abs(path, base):
    """Path relative to base, or absolute when it sits outside (e.g. an absolute recipe path)."""
    try:
        return str(path.relative_to(base)) or "."
    except ValueError:
        return str(path)


# ---------------------------------------------------------------- commands


def cmd_list(args):
    root = require_checkout(args.dir)
    index = readme_index(root)
    entries = {}
    for rel, meta in index.items():
        if (root / rel / "README.md").is_file():
            entries[rel] = {"title": meta["title"], "categories": meta["categories"], "description": meta["description"]}
    for d in recipe_dirs(root):
        rel = str(d.relative_to(root))
        if rel not in entries:
            entries[rel] = {"title": title_of(read(d / "README.md"), rel), "categories": ["Not in the README index"],
                            "description": ""}
    terms = [t.lower() for t in args.terms]
    results = []
    for rel in sorted(entries):
        e = entries[rel]
        hay = " ".join([rel, e["title"], e["description"], *e["categories"]]).lower()
        if terms and not all(t in hay for t in terms):
            continue
        d = root / rel
        text = read(d / "README.md")
        pods = pods_text_of(recipe_files(d), text)
        results.append({"path": rel, "title": e["title"], "category": ", ".join(e["categories"]),
                        "description": e["description"], "works_with": min_version(text),
                        "needs": needs_of(d, text, pods, unset_keys(d, pods))})
    status(f"{len(results)} recipe(s) in {root}" + (f" matching {' '.join(args.terms)!r}" if terms else ""))
    print("[")
    print(",\n".join(json.dumps(r) for r in results))
    print("]")


def resolve_recipe(root, name):
    s = name.strip()
    s = re.sub(r"^https?://github\.com/spiceai/cookbook/(?:tree|blob)/[^/]+/?", "", s)
    # Trailing slashes only: a leading one belongs to an absolute path.
    s = re.sub(r"/?README\.md$", "", s).rstrip("/")
    s = re.sub(r"^(\./)+", "", s)
    if s.startswith("cookbook/"):
        s = s[len("cookbook/"):]
    direct = Path(s).expanduser()
    if direct.is_absolute() and (direct / "README.md").is_file():
        return direct.resolve()
    if s and (root / s / "README.md").is_file():
        return (root / s).resolve()
    recipes = recipe_dirs(root)
    key = re.sub(r"[\s_]+", "-", s.lower())

    def norm(d):
        return str(d.relative_to(root)).lower().replace("_", "-")

    candidates = [d for d in recipes if norm(d) == key]
    if not candidates:
        # "postgres" names catalogs/postgres and everything under postgres/: ask.
        candidates = [d for d in recipes if norm(d).rsplit("/", 1)[-1] == key or norm(d).startswith(key + "/")]
    candidates = candidates or [d for d in recipes if key and key in norm(d)]
    if len(candidates) == 1:
        return candidates[0].resolve()
    names = [str(d.relative_to(root)) for d in candidates]
    if names:
        fail(f"'{name}' matches several recipes; pick one", candidates=names)
    fail(f"no recipe matches '{name}'; try `cookbook.sh list {name}`")


def cmd_inspect(args):
    root = require_checkout(args.dir)
    d = resolve_recipe(root, args.recipe)
    rel = rel_or_abs(d, root)
    readme = d / "README.md"
    text = read(readme)
    spice = spice_versions()
    runtime_v = parse_version(spice.get("runtime")) if spice.get("installed") else None
    minimum = min_version(text)
    deprecated = deprecated_in(text)
    precedence = env_precedence(runtime_v)

    run_dirs = recipe_files(d)
    pods_text = pods_text_of(run_dirs, text)
    connectors, s3_private = connectors_of(pods_text)
    # Compose is tracked separately: a daemon can be up while the compose plugin is missing.
    compose_needed = bool(compose_files(d)) or bool(re.search(r"docker[ -]compose", text))
    docker_needed = compose_needed or bool(re.search(r"docker run|docker build|docker exec", text))
    docker = docker_state() if docker_needed else None
    blockers, warnings = [], []

    if not spice["installed"]:
        blockers.append("The Spice CLI isn't installed.")
    elif not spice["on_path"]:
        warnings.append("spice is installed in ~/.spice/bin but that directory isn't on PATH.")
    if spice.get("runtime_installed") is False:
        warnings.append("The CLI has no runtime installed yet; `spice run` will download one.")
    meets = None
    if runtime_v and minimum:
        meets = runtime_v >= parse_version(minimum)
        if not meets:
            blockers.append(f"Runtime {spice['runtime']} is older than this recipe's minimum ({minimum}).")
    if deprecated and runtime_v and runtime_v >= parse_version(deprecated):
        blockers.append(f"The README marks this recipe deprecated in {deprecated}: it only runs on a runtime "
                        f"older than {deprecated.rstrip('+')}.")
    if docker_needed and docker and not docker["running"]:
        blockers.append("The recipe needs Docker, but the Docker daemon isn't reachable."
                        if docker["installed"] else "The recipe needs Docker, which isn't installed.")
    elif compose_needed and docker and not docker["compose"] and not docker["compose_standalone"]:
        blockers.append("The recipe runs Docker Compose, but this Docker install has no `docker compose` "
                        "plugin and no `docker-compose` binary.")

    # Secrets, evaluated from each directory `spice run` is started in.
    shell = dict(os.environ)
    secrets = []
    for rd in run_dirs or [d]:
        env_file = nearest(rd, ".env")
        local_file = nearest(rd, ".env.local")
        sources = {"shell": shell, ".env.local": parse_env(local_file), ".env": parse_env(env_file)}
        refs = secret_refs("".join(read(p) for p in spicepods_in(rd)) if run_dirs else pods_text)
        example = parse_env(rd / ".env.example")
        for key in example:
            refs.setdefault(key, ".env.example")
        for key, ref in refs.items():
            names = accepted_names(key) if ref != ".env.example" else [key]
            used = None
            for n in names:
                for src in precedence:
                    if n in sources[src]:
                        used = (n, src, sources[src][n])
                        break
                if used:
                    break
            if not used:
                state, variable, source = "missing", None, None
            else:
                variable, source, value = used
                state = "empty" if value.strip() == "" else "placeholder" if is_placeholder(value) else "set"
            # A usable value that loses to a placeholder is the v2.1.x trap.
            shadowed = [f"{n} in {src}" for n in names for src in precedence
                        if n in sources[src] and (n, src) != (variable, source) and sources[src][n].strip()
                        and not is_placeholder(sources[src][n])] if state in ("empty", "placeholder") else []
            entry = {"name": key, "referenced_as": ref, "run_dir": rel_or_abs(rd, root),
                     "status": state, "variable": variable, "source": source, "accepted_names": names}
            if source in (".env", ".env.local"):
                f = env_file if source == ".env" else local_file
                entry["file"] = str(f)
                entry["file_tracked_by_git"] = is_tracked(root, f)
            if shadowed:
                entry["ignored_values"] = shadowed
            # e.g. OPENAI_API_KEY is exported but the recipe reads SPICE_OPENAI_API_KEY.
            bare = key[len("SPICE_"):] if key.upper().startswith("SPICE_") else None
            hint = None
            if state != "set" and bare and shell.get(bare, "").strip() and bare not in names:
                entry["similar_in_shell"] = bare
                hint = f"{bare} is set in the shell, but this recipe reads {names[0]}"
            elif state != "set" and any(n in example and not is_placeholder(example[n]) for n in names):
                entry["demo_value_in_env_example"] = True
                hint = ".env.example has a demo value; the README may say to copy it to .env"
            secrets.append(entry)
            if state != "set" and ref != ".env.example":
                what = {"missing": "not set", "empty": "empty", "placeholder": "a placeholder"}[state]
                where = f" in {source}" if source else ""
                tracked = " (a file tracked by git)" if entry.get("file_tracked_by_git") else ""
                accepts = f"; the runtime accepts {' or '.join(names)}" if len(names) > 1 else ""
                message = f"{key} is {what}{where}{tracked}{accepts}." + (f" {hint}." if hint else "")
                if run_dirs:
                    blockers.append(message)
                else:  # from the README's example YAML, which may show alternatives
                    warnings.append(f"The README's spicepod reads {message}")
            if shadowed:
                warnings.append(f"{key}: a real value ({', '.join(shadowed)}) is ignored because {variable} in "
                                f"{source} takes precedence on runtime {spice.get('runtime')}.")
    if runtime_v and runtime_v[:2] == (2, 1) and any(s["source"] == ".env" for s in secrets):
        warnings.append("Runtime v2.1.x: values in .env override .env.local and exported variables (fixed in v2.2.0).")

    # A README that calls `python` or `pip` still works through python3/pip3, but the command as
    # written won't run, so name the substitute instead of staying silent.
    alternatives = {"python": "python3", "pip": "pip3"}
    tools = readme_commands(text)
    tool_state = {t: bool(shutil.which(t)) for t in tools}
    missing_tools, substitutes = [], []
    for tool, present in sorted(tool_state.items()):
        if present:
            continue
        alt = alternatives.get(tool)
        if alt and shutil.which(alt):
            tool_state[alt] = True
            substitutes.append((tool, alt))
        else:
            missing_tools.append(tool)
    if missing_tools:
        warnings.append(f"The README uses {', '.join(missing_tools)}, not found on PATH.")
    for tool, alt in substitutes:
        warnings.append(f"The README calls `{tool}`, which isn't on PATH; `{alt}` is — use it instead.")

    ports = {}
    for port in [8090, 50051, *compose_ports(d)]:
        owner = port_owner(port)
        ports[str(port)] = owner
        if owner:
            warnings.append(f"Port {port} is in use by {owner}.")

    if connectors & ACCOUNT_CONNECTORS or s3_private:
        which = sorted(connectors & ACCOUNT_CONNECTORS) + (["s3 (private bucket)"] if s3_private else [])
        warnings.append(f"Uses {', '.join(which)}: the user needs their own account and credentials.")
    if connectors & SERVICE_CONNECTORS and not docker_needed:
        warnings.append(f"Uses {', '.join(sorted(connectors & SERVICE_CONNECTORS))} with no compose file: "
                        "the user needs their own reachable server.")

    emit({
        "recipe": rel,
        "dir": str(d),
        "title": title_of(text, rel),
        "readme": str(readme),
        "readme_lines": text.count("\n"),
        "works_with": minimum,
        "deprecated_in": deprecated,
        "spice": {**spice, "meets_minimum": meets},
        "spicepods": [str(p.relative_to(d)) for rd in run_dirs for p in spicepods_in(rd)],
        "run_dirs": [str(rd.relative_to(d)) or "." for rd in run_dirs],
        "readme_writes_spicepod": not run_dirs,
        "connectors": sorted(connectors),
        "docker": {"needed": docker_needed, "compose_needed": compose_needed, "compose_files": compose_files(d),
                   "makefile": (d / "Makefile").is_file(), **(docker or {})},
        "env_precedence": precedence,
        "secrets": secrets,
        "tools": tool_state,
        "scripts": sorted(p.name for p in d.iterdir() if p.is_file() and p.suffix in (".sh", ".py") ),
        "ports_in_use": {p: o for p, o in ports.items() if o},
        "blockers": list(dict.fromkeys(blockers)),
        "warnings": list(dict.fromkeys(warnings)),
    })


def main():
    parser = argparse.ArgumentParser(prog="cookbook.sh", description="Find, fetch, and inspect Spice.ai cookbook recipes.")
    sub = parser.add_subparsers(dest="command", required=True)
    f = sub.add_parser("fetch", help="reuse or clone the cookbook, optionally at a PR or branch")
    f.add_argument("--dir")
    f.add_argument("--pr", type=int)
    f.add_argument("--ref")
    f.add_argument("--no-update", action="store_true")
    ls = sub.add_parser("list", help="list recipes, filtered by search terms")
    ls.add_argument("--dir")
    ls.add_argument("terms", nargs="*")
    ins = sub.add_parser("inspect", help="report what a recipe needs and what is in place")
    ins.add_argument("recipe")
    ins.add_argument("--dir")
    args = parser.parse_args()
    {"fetch": cmd_fetch, "list": cmd_list, "inspect": cmd_inspect}[args.command](args)


main()
PY
