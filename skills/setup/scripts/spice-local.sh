#!/bin/bash
set -e

# Take a local Spice project from an empty directory to a verified SQL result,
# using the Spice CLI and runtime already installed on this machine.
#
# Usage:
#   spice-local.sh preflight [DIR] [--http-port N] [--flight-port N]
#   spice-local.sh init DIR [--data PATH] [--format FMT] [--dataset NAME] [--name POD]
#   spice-local.sh start DIR [--http-port N] [--flight-port N] [--timeout SECS] [--no-wait]
#   spice-local.sh ready [DIR] [--http-port N] [--timeout SECS]
#   spice-local.sh verify [DIR] [--http-port N] [--dataset NAME]... [--sql SQL]
#   spice-local.sh stop [DIR]
#
#   preflight  Find the CLI and runtime (`spice version`), check the HTTP and
#              Flight ports, and inspect DIR's spicepod. Installs nothing.
#   init       Create DIR's spicepod with `spice init`, or reuse an empty one, and
#              add one local dataset: the bundled sample CSV, or --data PATH.
#   start      Start `spice run` in the background with a log file on free
#              loopback ports, then wait for readiness. Refuses when the runtime
#              is missing, because `spice run` would download one.
#   ready      Poll /v1/ready, then report each dataset's status, or why not.
#   verify     Check the expected datasets are Ready and a SQL query returns rows.
#   stop       Stop the runtime this script started for DIR, and only that one.
#
# Status goes to stderr; results go to stdout as JSON. Exits 0 when the step
# succeeded and 1 when it failed or found a blocker (the JSON says which).

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by spice-local.sh" >&2
  exit 1
fi

SPICE_LOCAL_SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export SPICE_LOCAL_SKILL_DIR

exec python3 - "$@" <<'PY'
import argparse
import hashlib
import json
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

SKILL_DIR = Path(os.environ["SPICE_LOCAL_SKILL_DIR"])
SAMPLE_CSV = SKILL_DIR / "examples" / "data" / "sales.csv"
DEFAULT_HTTP, DEFAULT_FLIGHT = 8090, 50051
STATE_DIR = Path(os.environ.get("TMPDIR") or "/tmp") / "spice-local"
INSTALL_DOCS = "https://spiceai.org/docs/installation"
FORMATS = {
    ".csv": "csv", ".tsv": "tsv", ".parquet": "parquet", ".json": "json", ".jsonl": "jsonl",
    ".md": "md", ".txt": "txt", ".pdf": "pdf", ".docx": "docx", ".xlsx": "xlsx", ".pptx": "pptx",
}
# In-memory (Arrow) acceleration loads the whole source at startup; above this,
# leave it off rather than exhaust a laptop's memory on the first run.
ACCELERATE_MAX_BYTES = 1 << 30
COMPONENTS = ("catalogs", "datasets", "views", "models", "embeddings", "rerankers", "tools",
              "workers", "functions", "dependencies")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Requests go to the local runtime only; never route them through a proxy.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def status(msg):
    print(msg, file=sys.stderr)


def emit(obj, ok=True):
    print(json.dumps({"ok": ok, **obj}, indent=2))
    sys.exit(0 if ok else 1)


def fail(msg, **extra):
    status(f"Error: {msg}")
    emit({"error": msg, **extra}, ok=False)


# ---------------------------------------------------------------- CLI and runtime


def find_cli():
    path = shutil.which("spice")
    if path:
        return path, True
    home = Path.home() / ".spice" / "bin" / "spice"
    if home.is_file() and os.access(home, os.X_OK):
        return str(home), False
    return None, False


def spice(cli, *args, cwd=None, input=None, timeout=60):
    kwargs = {"input": input} if input is not None else {"stdin": subprocess.DEVNULL}
    try:
        r = subprocess.run([cli, *args], cwd=cwd, capture_output=True, text=True, timeout=timeout, **kwargs)
    except (OSError, subprocess.TimeoutExpired) as err:
        return subprocess.CompletedProcess([cli, *args], 1, "", str(err))
    return subprocess.CompletedProcess(r.args, r.returncode, ANSI.sub("", r.stdout), ANSI.sub("", r.stderr))


def error_line(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    flagged = [line for line in lines if "ERROR" in line or "error" in line.lower()]
    return (flagged or lines or ["no output"])[-1]


def versions(cli):
    """`spice version` never installs anything; it reports what `spice run` would start."""
    info = {"cli": None, "runtime": None, "runtime_path": None, "runtime_source": None}
    r = spice(cli, "version", "-o", "json")
    if r.returncode == 0:
        try:
            data = json.loads(r.stdout)
            info.update({key: data.get(key) for key in info})
            return info, None
        except ValueError:
            pass
    # Older CLIs have no JSON output, and a bad SPICED_PATH fails both forms.
    t = spice(cli, "version")
    text = t.stdout + t.stderr
    match = re.search(r"CLI version:\s*(\S+)", text)
    info["cli"] = match.group(1) if match else None
    match = re.search(r"Runtime version:\s*(.+)", text)
    if match and "not installed" not in match.group(1):
        info["runtime"] = match.group(1).strip()
    if t.returncode != 0:
        return info, error_line(text)
    return info, None


def semver(value):
    match = re.match(r"v?(\d+)\.(\d+)\.(\d+)", value or "")
    return tuple(int(part) for part in match.groups()) if match else None


def require_cli():
    cli, on_path = find_cli()
    if not cli:
        fail("the Spice CLI is not installed or not on PATH", blocker="cli_missing", docs=INSTALL_DOCS,
             next="Installation is user-managed: point the user to the docs and continue once `spice version` works.")
    return cli


def require_runtime(cli):
    info, error = versions(cli)
    if error:
        fail(f"the CLI cannot resolve a runtime: {error}", blocker="runtime_unresolved", versions=info,
             next="Fix or unset SPICED_PATH, or have the user repair the installation; do not run `spice run`.")
    if not info["runtime"]:
        fail("the Spice runtime is not installed (`spice version` reports none)", blocker="runtime_missing",
             versions=info, docs=INSTALL_DOCS,
             next="Stop: `spice run` would download the runtime. Installation is user-managed.")
    return info


# ---------------------------------------------------------------- ports and HTTP


def listening(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def port_free(port):
    if listening(port):
        return False
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        # The runtime binds with SO_REUSEADDR, so TIME_WAIT sockets left by a
        # stopped runtime don't block it; don't let them block this check either.
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def first_free(start, avoid=()):
    for port in range(start, start + 200):
        if port not in avoid and port_free(port):
            return port
    return None


def http(method, port, path, body=None, headers=None, timeout=5):
    data = body.encode() if body is not None else None
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method,
                                     headers=headers or {})
    try:
        with OPENER.open(request, timeout=timeout) as response:
            return response.status, response.read().decode(errors="replace")
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode(errors="replace")
    except (urllib.error.URLError, OSError) as err:
        return None, str(err)


def occupant(port):
    """Describe whatever listens on a port, without touching it."""
    info = {"port": port, "pids": listener_pids(port)}
    code, body = http("GET", port, "/health", timeout=1)
    info["spice_runtime"] = code == 200 and body.strip() == "ok"
    if info["spice_runtime"]:
        info["datasets"] = [d.get("name") for d in dataset_status(port)]
    return info


def listener_pids(port):
    if not shutil.which("lsof"):
        return []
    r = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], capture_output=True, text=True)
    return sorted({int(p) for p in r.stdout.split() if p.isdigit()})


def parent_pid(pid):
    r = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True)
    return int(r.stdout.strip()) if r.stdout.strip().isdigit() else None


def owns_port(pid, port):
    """True/False when lsof can tell whether `pid` (or its spiced child) holds the port."""
    pids = listener_pids(port)
    if not pids or not pid:
        return None
    return any(p == pid or parent_pid(p) == pid for p in pids)


def dataset_status(port):
    code, body = http("GET", port, "/v1/datasets?status=true")
    if code != 200:
        return []
    try:
        rows = json.loads(body)
    except ValueError:
        return []
    keep = ("name", "from", "status", "error_message", "acceleration_enabled")
    return [{k: row[k] for k in keep if k in row} for row in rows if isinstance(row, dict)]


# ---------------------------------------------------------------- project state


def project_dir(value):
    return Path(value or ".").expanduser().resolve()


def find_pod(d):
    for name in ("spicepod.yaml", "spicepod.yml"):
        if (d / name).is_file():
            return d / name
    return None


def validate(cli, d):
    r = spice(cli, "validate", str(d))
    text = (r.stdout + r.stderr).strip()
    counts = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", text)}
    return r.returncode == 0, counts, text


def total(counts, keys=COMPONENTS):
    return sum(counts.get(key, 0) for key in keys)


def state_path(d):
    return STATE_DIR / (hashlib.sha1(str(d).encode()).hexdigest()[:12] + ".json")


def load_state(d):
    try:
        return json.loads(state_path(d).read_text())
    except (OSError, ValueError):
        return {}


def save_state(d, **fields):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state = {**load_state(d), **fields, "dir": str(d)}
    state_path(d).write_text(json.dumps(state, indent=2))
    return state


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def is_spice(pid):
    r = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
    return "spice" in r.stdout


def tail(path, lines=25):
    try:
        return Path(path).read_text(errors="replace").splitlines()[-lines:]
    except OSError:
        return []


def log_hints(lines):
    text = "\n".join(lines)
    hints = []
    if "Address already in use" in text:
        hints.append("A port is taken by another process. Run `start` without explicit ports to pick free ones.")
    if "No data files are yet available" in text:
        hints.append("The dataset path or file extension matches no files. Check `from:` and `file_format`.")
    if re.search(r"unknown (field|variant)|did not match any variant", text):
        hints.append("The spicepod uses a field this runtime version does not accept. Compare with `spice version`.")
    if re.search(r"secret|credential|password|api key", text, re.I) and "ERROR" in text:
        hints.append("A secret may be missing. Check the `${ store:KEY }` references and the user's env or .env files.")
    return hints


# ---------------------------------------------------------------- commands


def cmd_preflight(a):
    blockers, warnings = [], []
    result = {"target": "a local runtime on 127.0.0.1"}
    cli, on_path = find_cli()
    if not cli:
        blockers.append({"blocker": "cli_missing", "message": "The Spice CLI is not installed or not on PATH.",
                         "docs": INSTALL_DOCS})
        result["cli"] = None
    else:
        result["cli"] = {"path": cli, "on_path": on_path}
        if not on_path:
            warnings.append(f"The CLI exists at {cli} but is not on PATH. For this shell: "
                            'export PATH="$HOME/.spice/bin:$PATH"')
        info, error = versions(cli)
        result["cli"]["version"] = info["cli"]
        result["runtime"] = {"installed": bool(info["runtime"]), "version": info["runtime"],
                             "path": info["runtime_path"], "source": info["runtime_source"]}
        if error:
            blockers.append({"blocker": "runtime_unresolved", "message": error})
        elif not info["runtime"]:
            blockers.append({"blocker": "runtime_missing", "docs": INSTALL_DOCS,
                             "message": "No runtime is installed; `spice run` would download one."})
        cli_v, run_v = semver(info["cli"]), semver(info["runtime"])
        if cli_v and run_v and cli_v[:2] != run_v[:2]:
            warnings.append(f"CLI {info['cli']} and runtime {info['runtime']} are on different release lines.")

    ports = {}
    for label, wanted, default, scan in (("http", a.http_port, DEFAULT_HTTP, 18090),
                                          ("flight", a.flight_port, DEFAULT_FLIGHT, 15051)):
        port = wanted or default
        entry = {"port": port, "free": port_free(port)}
        if not entry["free"]:
            entry["occupant"] = occupant(port)
            entry["suggested"] = first_free(scan)
            warnings.append(f"{label} port {port} is in use; `start` will use {entry['suggested']} "
                            "unless you pass a port. Don't stop a process you didn't start.")
        ports[label] = entry
    result["ports"] = ports

    if a.dir:
        d = project_dir(a.dir)
        pod = find_pod(d)
        project = {"dir": str(d), "exists": d.is_dir(), "spicepod": str(pod) if pod else None}
        if pod and cli:
            ok, counts, text = validate(cli, d)
            project.update(valid=ok, components=counts, empty=ok and total(counts) == 0)
            if not ok:
                warnings.append("The spicepod does not validate: " + error_line(text))
            elif project["empty"]:
                warnings.append("The spicepod has no components. `validate` passing is not success: "
                                "run `init` to add a dataset before starting.")
        result["project"] = project

    result["blockers"], result["warnings"] = blockers, warnings
    if blockers:
        result["next"] = "Stop and explain the blocker. Installation and upgrades are user-managed."
    elif a.dir and not result["project"].get("spicepod"):
        result["next"] = f"spice-local.sh init {a.dir}"
    else:
        result["next"] = f"spice-local.sh start {a.dir or '.'}"
    emit(result, ok=not blockers)


def dataset_block(source, name, fmt, accelerate):
    if not re.fullmatch(r"[A-Za-z0-9_./:-]+", source):
        source = json.dumps(source)  # A double-quoted YAML scalar survives spaces, '#', and ': '.
    lines = ["datasets:", f"  - from: {source}", f"    name: {name}", "    params:", f"      file_format: {fmt}"]
    if accelerate:
        lines += ["    acceleration:", "      enabled: true"]
    return "\n".join(lines) + "\n"


def sanitize(stem):
    name = re.sub(r"[^a-z0-9_]+", "_", stem.lower()).strip("_") or "data"
    if name == "table":  # `FROM table` doesn't parse unquoted; other keywords do.
        return "table_data"
    return name if name[0].isalpha() else f"data_{name}"


def size_of(path):
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def seed_source(a, d):
    """Return (from, dataset name, file_format, accelerate, note) for the dataset to add."""
    if a.data:
        path = Path(a.data).expanduser().resolve()
        if not path.exists():
            fail(f"--data {a.data} does not exist")
        if path.is_file():
            fmt = a.format or FORMATS.get(path.suffix.lower())
        else:
            suffixes = sorted({p.suffix.lower() for p in path.rglob("*") if p.suffix.lower() in FORMATS})
            fmt = a.format or (FORMATS[suffixes[0]] if len(suffixes) == 1 else None)
        if not fmt:
            fail(f"cannot tell the file format of {path}; pass --format ({', '.join(sorted(set(FORMATS.values())))})")
        try:
            relative = path.relative_to(d)
            location = f"./{relative.as_posix()}"
        except ValueError:
            location = path.as_posix()
        if path.is_dir():
            location = location.rstrip("/") + "/"
        accelerate = size_of(path) <= ACCELERATE_MAX_BYTES
        note = None if accelerate else ("The source is over 1 GiB, so in-memory acceleration is off; queries "
                                        "read the file directly. See the acceleration skill to choose an engine.")
        return f"file:{location}", a.dataset or sanitize(path.stem if path.is_file() else path.name), fmt, accelerate, note

    target = d / "data" / "sales.csv"
    note = None
    if target.exists():
        note = f"Kept the existing {target}; it was not overwritten."
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SAMPLE_CSV, target)
    return "file:./data/sales.csv", a.dataset or "sales", "csv", True, note


def cmd_init(a):
    cli = require_cli()
    d = project_dir(a.dir)
    pod = find_pod(d)
    created = False
    if pod:
        ok, counts, text = validate(cli, d)
        if not ok:
            fail("the existing spicepod does not validate; fix it before seeding", spicepod=str(pod), validate=text)
        pod_text = pod.read_text()
        has_datasets_key = re.search(r"^datasets\s*:", pod_text, re.M) is not None
        if has_datasets_key or (total(counts) > 0 and not a.data):
            source, name, fmt, accelerate, _ = seed_source(a, d) if a.data else (None, None, None, None, None)
            result = {"status": "existing", "dir": str(d), "spicepod": str(pod), "components": counts,
                      "validate": text}
            if counts.get("datasets", 0) == 0 and total(counts, ("catalogs", "dependencies")) == 0:
                result["next"] = ("The spicepod has no datasets and was left unchanged. Add one under its "
                                  "`datasets:` key (see connectors), or pass --data PATH if it has no such key.")
                if a.data:
                    result["snippet"] = dataset_block(source, name, fmt, accelerate)
                emit(result, ok=False)
            if a.data:
                result["snippet"] = dataset_block(source, name, fmt, accelerate)
                result["next"] = "Add the snippet's list item under the existing `datasets:` key, then start."
                emit(result, ok=False)
            result["next"] = f"spice-local.sh start {a.dir}"
            emit(result)
    else:
        d.mkdir(parents=True, exist_ok=True)
        # `spice init` with no argument asks for the pod name; answer from stdin so it never waits.
        pod_name = a.name or d.name
        r = spice(cli, "init", cwd=d, input=f"{pod_name}\n")
        pod = find_pod(d)
        if r.returncode != 0 or not pod:
            fail("`spice init` failed", output=(r.stdout + r.stderr).strip())
        created = True

    source, name, fmt, accelerate, note = seed_source(a, d)
    pod_text = pod.read_text()
    addition = ""
    if not re.search(r"^secrets\s*:", pod_text, re.M):
        addition += "\nsecrets:\n  - from: env\n    name: env\n"
    addition += "\n" + dataset_block(source, name, fmt, accelerate)
    pod.write_text(pod_text.rstrip("\n") + "\n" + addition)

    ok, counts, text = validate(cli, d)
    if not ok or counts.get("datasets", 0) < 1:
        fail("the seeded spicepod does not validate", spicepod=str(pod), validate=text)
    save_state(d, datasets=[name])
    result = {"status": "created" if created else "seeded_existing", "dir": str(d), "spicepod": str(pod),
              "dataset": {"name": name, "from": source, "file_format": fmt, "accelerated": accelerate},
              "components": counts, "validate": text,
              "next": f"spice-local.sh start {a.dir}  (validate passing is not success; the runtime must serve rows)"}
    if note:
        result["note"] = note
    emit(result)


def choose_ports(http_port, flight_port):
    """Return (http, flight, notes, moved); `moved` maps a label to the default it replaced and who holds it."""
    chosen, notes, moved = {}, [], {}
    for label, wanted, default, scan in (("http", http_port, DEFAULT_HTTP, 18090),
                                          ("flight", flight_port, DEFAULT_FLIGHT, 15051)):
        if wanted:
            if not port_free(wanted):
                fail(f"{label} port {wanted} is in use", occupant=occupant(wanted),
                     next="Pick another port, or omit it to choose a free one. Don't stop a process you didn't start.")
            chosen[label] = wanted
        elif port_free(default):
            chosen[label] = default
        else:
            chosen[label] = first_free(scan, avoid=chosen.values())
            if not chosen[label]:
                fail(f"no free {label} port found near {scan}")
            holder = occupant(default)
            moved[label] = {"default": default, "port": chosen[label], "occupant": holder}
            notes.append(f"{label} port {default} is in use ({json.dumps(holder)}); using {chosen[label]} instead")
    return chosen["http"], chosen["flight"], notes, moved


def wait_ready(d, state, timeout, proc=None, notes=()):
    port, pid, log = state["http_port"], state.get("pid"), state.get("log")
    started = time.time()
    status(f"Waiting for http://127.0.0.1:{port}/v1/ready (up to {timeout}s) ...")
    while True:
        exited = proc.poll() is not None if proc else (pid is not None and not alive(pid))
        if exited:
            lines = tail(log)
            fail("the runtime exited before it was ready", exit_code=proc.returncode if proc else None,
                 log=log, log_tail=lines, hints=log_hints(lines))
        code, body = http("GET", port, "/v1/ready", timeout=2)
        if code == 200 and body.strip() == "ready":
            break
        if time.time() - started > timeout:
            lines = tail(log)
            fail(f"not ready after {timeout}s", ready_response=body.strip()[:200], datasets=dataset_status(port),
                 log=log, log_tail=lines, hints=log_hints(lines),
                 next="Datasets still loading can take minutes (remote sources, models); re-run `ready` "
                      "with a longer --timeout. A dataset with status Error needs a config fix first.")
        time.sleep(1)

    if owns_port(pid, port) is False:
        fail(f"another process answers on port {port}, not the runtime this script started",
             occupant=occupant(port), pid=pid, log=log)
    emit({"status": "ready", "dir": str(d), "pid": pid, "http": f"http://127.0.0.1:{port}",
          "flight": f"127.0.0.1:{state.get('flight_port')}" if state.get("flight_port") else None,
          "log": log, "seconds": round(time.time() - started, 1), "datasets": dataset_status(port),
          "notes": list(notes), "next": f"spice-local.sh verify {state.get('dir', '.')}"})


def cmd_start(a):
    d = project_dir(a.dir)
    pod = find_pod(d)
    if not pod:
        fail(f"no spicepod.yaml in {d}", next=f"spice-local.sh init {a.dir}")
    cli = require_cli()
    require_runtime(cli)
    ok, counts, text = validate(cli, d)
    if not ok:
        fail("the spicepod does not validate", validate=text)
    if total(counts) == 0:
        fail("the spicepod is empty, so a running runtime would prove nothing", validate=text,
             next=f"spice-local.sh init {a.dir}  (adds a dataset to the empty spicepod)")

    state = load_state(d)
    if state.get("pid") and alive(state["pid"]) and is_spice(state["pid"]):
        status(f"A runtime this script started for {d} is already running (PID {state['pid']}).")
        wait_ready(d, state, a.timeout, notes=["already running; not started again"])

    http_port, flight_port, notes, moved = choose_ports(a.http_port, a.flight_port)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    pod_name = re.sub(r"[^A-Za-z0-9_-]+", "_", d.name) or "spice"
    log = STATE_DIR / f"{pod_name}-{http_port}.log"
    command = [cli, "run"]
    if (http_port, flight_port) != (DEFAULT_HTTP, DEFAULT_FLIGHT):
        command += ["--http-endpoint", f"127.0.0.1:{http_port}", "--flight-endpoint", f"127.0.0.1:{flight_port}"]
    status(f"Starting `{' '.join(command[1:])}` in {d}; log: {log}")
    with open(log, "w") as handle:
        # A new session keeps the runtime alive after this script and its shell exit.
        proc = subprocess.Popen(command, cwd=d, stdin=subprocess.DEVNULL, stdout=handle,
                                stderr=subprocess.STDOUT, start_new_session=True)
    state = save_state(d, pid=proc.pid, http_port=http_port, flight_port=flight_port, log=str(log),
                       command=command, started_at=time.time(), moved=moved)
    if a.no_wait:
        emit({"status": "started", "dir": str(d), "pid": proc.pid, "http": f"http://127.0.0.1:{http_port}",
              "flight": f"127.0.0.1:{flight_port}", "log": str(log), "notes": notes,
              "next": f"spice-local.sh ready {a.dir}"})
    wait_ready(d, state, a.timeout, proc=proc, notes=notes)


def cmd_ready(a):
    d = project_dir(a.dir)
    state = load_state(d)
    if a.http_port:
        state = {"http_port": a.http_port, "dir": str(d)}  # a runtime this script did not start
    if not state.get("http_port"):
        state = {"http_port": DEFAULT_HTTP, "dir": str(d)}
    wait_ready(d, state, a.timeout)


def quote_identifier(name):
    return ".".join('"' + part.replace('"', '""') + '"' for part in name.split("."))


def markdown_table(rows):
    columns = list(rows[0].keys())
    cell = lambda value: str(value).replace("|", "\\|").replace("\n", " ")
    lines = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    lines += ["| " + " | ".join(cell(row.get(c, "")) for c in columns) + " |" for row in rows]
    return "\n".join(lines)


def build_report(d, state, port, datasets, sql, rows, total_rows):
    """Everything the user needs in one block: where it runs, how to reach and stop it, and proof."""
    pid, log = state.get("pid"), state.get("log")
    lines = [f"Spice is running in {d}"]
    if pid:
        lines.append(f"- PID {pid} (`spice run`), log {log}")
    else:
        lines.append("- Runtime started outside this helper (no PID recorded)")
    flight = f", Flight 127.0.0.1:{state['flight_port']}" if state.get("flight_port") else ""
    lines.append(f"- HTTP http://127.0.0.1:{port}{flight}")
    moved = state.get("moved") or {}
    if moved:
        holders = [info.get("occupant", {}) for info in moved.values()]
        defaults = " and ".join(str(moved[k]["default"]) for k in ("http", "flight") if k in moved)
        pids = sorted({p for h in holders for p in h.get("pids", [])})
        served = next((h["datasets"] for h in holders if h.get("datasets")), None)
        what = (f" (a Spice runtime serving {', '.join(served)})" if served else
                " (another Spice runtime)" if any(h.get("spice_runtime") for h in holders) else "")
        who = f"PID {', '.join(map(str, pids))}" if pids else "another process"
        plural = len(moved) > 1
        elsewhere = []
        if "flight" in moved:
            elsewhere.append(f"`spice sql` needs `--endpoint grpc://127.0.0.1:{state.get('flight_port')}`")
        if "http" in moved:
            elsewhere.append(f"HTTP clients need port {port}")
        lines.append(f"- {'Ports' if plural else 'Port'} {defaults} {'were' if plural else 'was'} taken by "
                     f"{who}{what}, which was left running, so {' and '.join(elsewhere)}; "
                     f"the defaults reach the other process.")
    for row in datasets:
        count = f", {total_rows} rows" if total_rows is not None and sql.endswith(
            f"FROM {quote_identifier(row['name'])} LIMIT 5") else ""
        lines.append(f"- Dataset {row['name']} ({row.get('from', '?')}): {row.get('status', 'loaded')}{count}")
    lines += ["", f"`{sql}` returned {len(rows)} row{'s' if len(rows) != 1 else ''}:", "", markdown_table(rows[:5])]
    if pid:
        lines += ["", f"Stop it with `spice-local.sh stop {d}` or `kill {pid}`."]
    return "\n".join(lines)


def cmd_verify(a):
    d = project_dir(a.dir)
    state = load_state(d)
    port = a.http_port or state.get("http_port") or DEFAULT_HTTP
    code, body = http("GET", port, "/v1/ready", timeout=3)
    if code != 200:
        fail(f"the runtime on port {port} is not ready ({code or body})", next=f"spice-local.sh ready {a.dir or '.'}")
    if not a.http_port and state.get("pid") and owns_port(state["pid"], port) is False:
        fail(f"port {port} is served by a different process than the runtime started for {d}",
             occupant=occupant(port))

    datasets = dataset_status(port)
    names = [row.get("name") for row in datasets]
    expected = a.dataset or state.get("datasets") or names
    missing = [name for name in expected if name not in names]
    unready = [row for row in datasets if row.get("name") in expected and row.get("status", "Ready") != "Ready"]
    if missing or unready:
        fail("expected datasets are missing or not Ready", missing=missing, not_ready=unready, datasets=datasets)
    if not expected and not a.sql:
        fail("the runtime serves no datasets, so there is nothing to query",
             next="Add a dataset (init --data PATH, or see connectors), or pass --sql for catalog tables.")

    headers = {"Content-Type": "text/plain", "Accept": "application/json"}
    total_rows = None
    if a.sql:
        sql = a.sql
    else:
        table = quote_identifier(expected[0])
        sql = f"SELECT * FROM {table} LIMIT 5"
        code, body = http("POST", port, "/v1/sql", body=f"SELECT COUNT(*) AS row_count FROM {table}",
                          headers=headers, timeout=60)
        if code == 200:
            try:
                total_rows = json.loads(body)[0]["row_count"]
            except (ValueError, LookupError, TypeError):
                pass
    code, body = http("POST", port, "/v1/sql", body=sql, headers=headers, timeout=120)
    if code != 200:
        fail(f"the query failed with HTTP {code}", sql=sql, response=body[:2000])
    try:
        rows = json.loads(body)
    except ValueError:
        fail("the query returned a non-JSON response", sql=sql, response=body[:2000])
    if not isinstance(rows, list) or not rows:
        fail("the query returned no rows", sql=sql,
             next="An empty source is not a verified setup. Check the data, or query a dataset that has rows.")
    emit({"status": "verified", "dir": str(d), "pid": state.get("pid"), "http": f"http://127.0.0.1:{port}",
          "flight": f"127.0.0.1:{state['flight_port']}" if state.get("flight_port") else None,
          "log": state.get("log"), "datasets": datasets, "sql": sql, "rows_returned": len(rows),
          "total_rows": total_rows, "sample": rows[:5],
          "report": build_report(d, state, port, datasets, sql, rows, total_rows)})


def cmd_stop(a):
    d = project_dir(a.dir)
    state = load_state(d)
    pid = state.get("pid")
    if not pid and state.get("http_port"):
        emit({"status": "not_running", "dir": str(d), "log": state.get("log")})
    if not pid:
        fail(f"no runtime started by this script is recorded for {d}",
             next="Find your own runtime's PID; never `pkill spiced`, which stops other projects' runtimes.")
    if not alive(pid):
        save_state(d, pid=None)
        emit({"status": "not_running", "dir": str(d), "pid": pid})
    if not is_spice(pid):
        save_state(d, pid=None)
        fail(f"PID {pid} is no longer a spice process; not signalling it", pid=pid)
    os.kill(pid, signal.SIGTERM)  # `spice run` forwards this to its spiced child.
    for _ in range(60):
        if not alive(pid):
            break
        time.sleep(0.5)
    forced = alive(pid)
    if forced:
        os.kill(pid, signal.SIGKILL)
    save_state(d, pid=None)
    port = state.get("http_port")
    emit({"status": "stopped", "dir": str(d), "pid": pid, "forced": forced,
          "http_still_answering": bool(port and listening(port)), "log": state.get("log")})


def main():
    parser = argparse.ArgumentParser(prog="spice-local.sh", description="Local Spice project lifecycle")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("preflight", help="check the CLI, runtime, ports, and project")
    p.add_argument("dir", nargs="?")
    p.add_argument("--http-port", type=int)
    p.add_argument("--flight-port", type=int)
    p.set_defaults(func=cmd_preflight)

    p = sub.add_parser("init", help="create or reuse an empty spicepod and add one local dataset")
    p.add_argument("dir")
    p.add_argument("--data", help="a local file or directory to query instead of the sample CSV")
    p.add_argument("--format", help="file_format when the extension doesn't say (csv, parquet, json, ...)")
    p.add_argument("--dataset", help="dataset name (default: sales, or the --data file name)")
    p.add_argument("--name", help="spicepod name for a new project (default: the directory name)")
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("start", help="start `spice run` in the background and wait until ready")
    p.add_argument("dir", nargs="?", default=".")
    p.add_argument("--http-port", type=int)
    p.add_argument("--flight-port", type=int)
    p.add_argument("--timeout", type=int, default=120)
    p.add_argument("--no-wait", action="store_true")
    p.set_defaults(func=cmd_start)

    p = sub.add_parser("ready", help="poll /v1/ready and report dataset status")
    p.add_argument("dir", nargs="?", default=".")
    p.add_argument("--http-port", type=int)
    p.add_argument("--timeout", type=int, default=120)
    p.set_defaults(func=cmd_ready)

    p = sub.add_parser("verify", help="check datasets are Ready and a SQL query returns rows")
    p.add_argument("dir", nargs="?", default=".")
    p.add_argument("--http-port", type=int)
    p.add_argument("--dataset", action="append")
    p.add_argument("--sql")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("stop", help="stop the runtime this script started for DIR")
    p.add_argument("dir", nargs="?", default=".")
    p.set_defaults(func=cmd_stop)

    args = parser.parse_args()
    args.func(args)


main()
PY
