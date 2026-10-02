---
name: setup
description: Start here to get Spice.ai working end to end — take a directory from nothing to a running local runtime that answers SQL with real rows. Checks the existing installation, creates or reuses a spicepod, seeds a local dataset, starts `spice run` in the background, waits for /v1/ready, and verifies with a query, using a bundled helper script. Also the reference for the Spice CLI, runtime ports and endpoints, and the /v1/sql request format. Installation and upgrades get documentation guidance only; this skill does not install software. Use it whenever the user wants to set up, try, start, run, or get started with Spice, create a new Spice project or spicepod, see a first query result, asks why `spice sql` shows no tables, how to install Spice, or which port or HTTP endpoint to use. For a cookbook recipe use cookbook; to add a specific source to a project that already runs, use connectors.
---

# Set Up Spice

Spice is an open-source SQL query, search, and LLM-inference engine written in Rust. It federates
queries across 30+ data sources, accelerates data locally, and integrates search and AI — all
configured declaratively in YAML. It is not a replacement for a transactional database or a data
warehouse; it is the operational data and AI layer between applications and their data.

This skill is the entry point: it takes the user from an empty directory to a runtime serving rows
from a real dataset, then hands off to the specialist skills. A helper, `scripts/spice-local.sh` in
this skill's directory, does the mechanical parts — call it by its full path. Status goes to stderr
and results to stdout as JSON; it exits 1 when a step fails, with the reason and next step in the JSON.

| Command | What it does |
| --- | --- |
| `spice-local.sh preflight [DIR]` | Finds the CLI and runtime with `spice version`, checks ports 8090 and 50051 and who holds them, and inspects DIR's spicepod. Installs nothing |
| `spice-local.sh init DIR [--data PATH]` | Creates the spicepod with `spice init` (or reuses an empty one) and adds one local dataset: a bundled 20-row sample CSV, or the user's file or directory |
| `spice-local.sh start DIR` | Starts `spice run` in the background on free loopback ports with a log file, then waits for `/v1/ready`. Refuses when the runtime is missing or the spicepod is empty |
| `spice-local.sh ready [DIR]` | Polls `/v1/ready`; on a timeout, reports each dataset's status and error |
| `spice-local.sh verify [DIR] [--sql SQL]` | Checks the datasets are `Ready` and a query returns rows, and prints a sample |
| `spice-local.sh stop [DIR]` | Stops the runtime it started for DIR, and nothing else |

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.2). Check the user's runtime version before recommending configuration:

- **Find it**: `spice version` (CLI and runtime), `spiced --version`, or the image tag (`spiceai/spiceai:<tag>`, Helm `image.tag`). Not the runtime version: `version: v2` in `spicepod.yaml` (manifest schema) or SQL `version()` (DataFusion).
- **Markers**: unmarked content applies to v2.0.0 and later. Later additions are marked `(vX.Y.Z+)`; changes are marked **Removed**, **Deprecated**, **Changed**, or **Breaking in vX.Y.Z**.
- **Older runtime**: don't recommend a newer feature — use configuration supported by that version or explain the user-managed upgrade prerequisite — and read that release line's docs, e.g. `https://spiceai.org/docs/v2.2/...` (`/docs/next/` tracks trunk, not a release). On v1.x, use the [v1.11 docs](https://spiceai.org/docs/v1.11) and the [v2.0 upgrade guide](https://spiceai.org/releases/v2.0-stable#upgrade-guide-from-v1x).
- **Newer runtime**: check the [release notes](https://spiceai.org/releases) for changes after v2.3.2.

| Old | Change | Use instead |
| --- | --- | --- |
| `evals:` section, `/v1/evals` | Removed in v2.0.0 | Nothing — delete the section |
| ONNX models, `/v1/predict` | Removed in v2.2.0 | An LLM provider (see models) |
| `version: v1beta1` | Removed in v2.0.0 | `version: v2` (`v1` still loads, auto-migrated) |
| `models` build variant, `-models` image tags | Removed in v2.0.0 | The default build or image (includes models) |
| Native Windows runtime (`spiced.exe`) | Removed in v2.0.0 | WSL |
| OpenTelemetry port `50052` | Removed in v1.11.0 | The Flight port `50051` |
| `spice connect <org>/<pod>` | Deprecated in v2.2.0 | `spice add <org>/<pod>` |
| `spice run -- --http <addr>` | Fails on every v2 CLI (the CLI already passes `--http`) | `spice run --http-endpoint <addr>` |
| Browser `Origin` on `/v1/mcp` | Breaking in v2.3.1 (checked, else `403`) | List origins in `runtime.cors.allowed_origins` |

## What "working" means

A passing `spice validate` or a started process is not a working setup. `spice validate` reports `OK`
for a spicepod with zero datasets, and for one whose data file doesn't exist; a runtime started on
an empty spicepod has nothing to query. Report success only when all of these hold:

1. `spice version` shows both a CLI and a runtime version, not `Runtime version: not installed`.
2. `spicepod.yaml` has `version: v2` and at least one dataset (or a catalog or dependency providing tables).
3. The runtime you started is still running, and each dataset reports `Ready` in
   `GET /v1/datasets?status=true`. A failing dataset may log only `WARN` lines, so don't rely on
   grepping the log for `ERROR`.
4. `GET /v1/ready` returns `ready` (HTTP 200) from that runtime.
5. The datasets list includes the names you expect.
6. `POST /v1/sql` returns at least one row for a query against one of them.
7. You tell the user the directory, PID, HTTP and Flight addresses, log path, and sample rows.

`start` and `verify` check 1–6, and their JSON contains everything 7 needs.

## Installation prerequisite

This skill configures and operates an existing Spice installation. Software installation and
upgrades are user-managed prerequisites: provide the [official installation documentation](https://spiceai.org/docs/installation)
for the user's platform, then continue once the CLI and runtime are installed. Do not fetch or
execute installers, invoke package managers, install the runtime, or upgrade binaries as part of
this workflow. Do not use another skill or a linked page to perform those provisioning steps.
Explain this boundary when a request includes installation; do not report installation as complete.

The OSS runtime (`spiced`) does not run natively on Windows (**Removed in v2.0.0**). Use an
existing [WSL](https://learn.microsoft.com/en-us/windows/wsl/) installation for the local runtime;
the Windows CLI can connect to a runtime running elsewhere.

### Check the existing installation

`spice-local.sh preflight` does this check. By hand:

```bash
command -v spice
spice version
```

If the CLI is not found, check whether the user's existing binary is under `$HOME/.spice/bin`.
Only when it exists, expose it in the current shell with `export PATH="$PATH:$HOME/.spice/bin"`.
If it is absent, stop before running CLI commands and explain the installation prerequisite.

**Before starting a local runtime, require `spice version` to report an installed runtime.**
A CLI version alone is insufficient. If the runtime is `not installed`, the check fails, or the
runtime location is uncertain, stop before `spice run`. That command automatically installs a
missing runtime; using it to repair an incomplete installation is outside this workflow. A first
install often has only the CLI. Explain that the runtime is a separate, user-managed download,
link the installation documentation, and re-run preflight once the user has installed it.

The CLI and runtime are separate executables. `spice run` and `spice version` resolve `spiced`
in the same order (**Changed in v2.3.0**) — `$SPICED_PATH`, then beside the running `spice`
binary, then `$HOME/.spice/bin/spiced`, then (under `sudo`) the invoking user's copy. `spice version`
is non-mutating and reports `not installed` when absent. `PATH` is not searched for the runtime.
An invalid `SPICED_PATH` is an error, not a fallback; retain a user-configured path to their existing
runtime. For an older CLI whose runtime selection differs, run the user's known installed `spiced`
binary directly rather than relying on CLI auto-install behavior. See the [run reference](https://spiceai.org/docs/cli/reference/run).

### When the user's own install attempt failed

Diagnose and explain, then point to the installation documentation; the user performs any fix.
Don't give installer or package-manager commands.

| Symptom | Cause | What to tell the user |
| --- | --- | --- |
| A download URL containing `/download//`, then `Failed to extract archive` | The installer couldn't read the latest release tag (usually GitHub's anonymous API rate limit), so the version in the URL is empty | It's a transient lookup failure, not a broken machine: retry later, use another method from the installation docs, or download a specific release's archives (such as v2.3.2) from [GitHub releases](https://github.com/spiceai/spiceai/releases) |
| `spice: command not found` right after installing | The installer edited a shell profile that this shell hasn't loaded | Check `$HOME/.spice/bin` as above, or open a new shell |
| `Runtime version: not installed` | Only the CLI is installed | The runtime prerequisite above |

## First working project

Use this for "set up Spice", "get Spice running in ./my_app", "show me a query result", or a project
where `spice sql` shows no tables. For an existing project with its own datasets, skip step 2.

1. **Preflight**: `spice-local.sh preflight ./my_app`. If `blockers` lists `cli_missing`,
   `runtime_missing`, or `runtime_unresolved`, stop and follow the installation prerequisite.
   Warnings about busy ports are informational: `start` works around them.
2. **Create and seed**: `spice-local.sh init ./my_app`. It runs `spice init`, copies the sample to
   `data/sales.csv`, adds the block below, and runs `spice validate`:

   ```yaml
   secrets:
     - from: env
       name: env

   datasets:
     - from: file:./data/sales.csv
       name: sales
       params:
         file_format: csv
       acceleration:
         enabled: true
   ```

   For the user's own data, pass `--data path/to/orders.csv` — csv, tsv, parquet, json, jsonl, or
   documents such as md and pdf; a directory needs a single format or `--format`. The file is
   referenced where it is, not copied, and sources over 1 GiB are not accelerated in memory. For a
   database or cloud source, seed the sample first and add the real source afterwards with connectors
   and secrets, so a credential problem can't be mistaken for a setup problem.

   With an existing spicepod, `init` adds the dataset only when the spicepod has no components (as
   left by `spice init`), or when you pass `--data` and it has no `datasets:` key. Otherwise it
   changes nothing and returns `existing` — go on to `start` — or a snippet to paste under the
   existing `datasets:` key.
3. **Start**: `spice-local.sh start ./my_app`. It runs `spice run` from the project directory, so
   relative `file:./` paths and `.env` files resolve there, and `spice run` reloads `spicepod.yaml`
   when it changes. If 8090 or 50051 is taken, it picks free ports and says so in `notes`; it never
   stops another process. Local files are ready in seconds. Remote sources and model downloads can
   take minutes: re-run `ready` with a longer `--timeout` rather than restarting. A dataset with
   status `Error` needs a configuration fix; its `error_message` says what.
4. **Verify**: `spice-local.sh verify ./my_app` runs `SELECT COUNT(*)` and `SELECT * … LIMIT 5`
   against the seeded dataset and fails on zero rows. When the user asked a question of the data,
   pass that query instead, so the proof and the answer arrive together:
   `verify ./my_app --sql "SELECT customer, SUM(amount) AS total FROM orders GROUP BY customer ORDER BY total DESC LIMIT 3"`.
5. **Report**: show the user verify's `report` field as it is, even when they asked a specific
   question — put the answer first, then the report. It covers criterion 7: the directory, PID, HTTP
   and Flight addresses, log path, each dataset's status and row count, the sample rows as a table,
   and how to stop the runtime. The runtime outlives this conversation, and the PID and log path are
   how the user later finds, debugs, or stops it, so don't summarize them away. For example:

   ```text
   Spice is running in /Users/me/my_app
   - PID 61565 (`spice run`), log /var/folders/…/spice-local/my_app-8090.log
   - HTTP http://127.0.0.1:8090, Flight 127.0.0.1:50051
   - Dataset sales (file:./data/sales.csv): Ready, 20 rows
   `SELECT * FROM "sales" LIMIT 5` returned 5 rows: <table>
   Stop it with `spice-local.sh stop /Users/me/my_app` or `kill 61565`.
   ```

   Add the answer to the user's actual question, if they asked one, then offer next steps: a query or
   two (`SELECT region, SUM(quantity * unit_price) AS revenue FROM sales GROUP BY region ORDER BY
   revenue DESC`) and the specialist skills below. Leave the runtime running unless the user only
   wanted a check.

### Without the helper

When `python3` is unavailable, do the same by hand:

```bash
spice version                     # stop if the runtime is "not installed"
spice init my_app && cd my_app    # an empty spicepod; not done yet
mkdir -p data && cp <this-skill-dir>/examples/data/sales.csv data/
# append the secrets and datasets block above to spicepod.yaml
spice validate                    # expect datasets=1; syntax only, not proof the data loads
lsof -nP -iTCP:8090 -sTCP:LISTEN  # must print nothing; otherwise use other ports (below)
nohup spice run > spice.log 2>&1 & echo $!   # record this PID
for i in $(seq 1 120); do curl -sf http://127.0.0.1:8090/v1/ready && break; sleep 1; done
curl -s 'http://127.0.0.1:8090/v1/datasets?status=true'
curl -s -X POST http://127.0.0.1:8090/v1/sql -H 'Content-Type: text/plain' -d 'SELECT * FROM sales LIMIT 5'
```

While polling, check that the recorded PID is still alive. If another runtime already holds 8090,
your `spice run` exits with `Address already in use`, yet `/v1/ready` still answers `ready` — from
the other runtime. Use free ports instead: `spice run --http-endpoint 127.0.0.1:18090
--flight-endpoint 127.0.0.1:15051`, and point curl and `spice sql --endpoint grpc://127.0.0.1:15051` at them.
The complete seeded manifest is in `examples/spicepod.local-csv.yaml`.

## Querying over HTTP

`POST /v1/sql` takes the SQL statement as the raw request body, the form every example in these skills uses:

```bash
curl -s -X POST http://127.0.0.1:8090/v1/sql -H 'Content-Type: text/plain' -d 'SELECT * FROM sales LIMIT 5'
```

A JSON body is for parameterized queries, and then `parameters` is required:

| Request | Result |
| --- | --- |
| Raw SQL body with any non-JSON `Content-Type` (`text/plain`, or curl's default for `-d`) | 200 |
| `Content-Type: application/json` with `{"sql": "..."}` | **400** `Invalid JSON: missing field 'parameters'` |
| `{"sql": "...", "parameters": []}` or `"parameters": {}` | 200 |
| `{"sql": "... WHERE region = $1", "parameters": ["west"]}`, or `:r` with `{"r": "west"}` | 200 |
| `"parameters": null` | 400 |
| `Content-Type: application/json; charset=utf-8` | 400 — only exactly `application/json` is parsed as JSON; any other type is read as SQL |

Responses are a JSON array of row objects; `Accept: text/csv`, `text/plain` (a table), or
`application/vnd.spiceai.sql.v1+json` (rows with schema) change the format. `spice sql --query
"SELECT ..."` runs one query over Flight without curl.

## Don't

- **Stop after `spice init`.** It writes an empty spicepod, and its suggested next steps
  (`spice dataset configure`, which is interactive, then `spice run`) lead to a runtime with nothing
  to query. Seed a dataset first.
- **Treat `spice validate` as proof.** It checks syntax and references, not whether data loads or
  the runtime starts: a missing data file and an unreadable TLS certificate both validate.
- **Run `pkill spiced`, or kill a process you didn't start.** Other projects' runtimes on the machine
  would stop too. Stop the PID you recorded; `spice run` forwards the signal to its `spiced` child.
- **Send JSON to `/v1/sql` without `"parameters"`.** See the table above.
- **Add `--metrics-endpoint` or other optional services on the first run.** A taken metrics port
  (9090 is also Prometheus's default) makes the runtime exit. Enable metrics once the pod is green.
- **Fetch a remote pod to fill a starter project.** `spice add spiceai/quickstart` downloads a
  `version: v1` pod (auto-migrated) that loads taxi data from public S3: network-dependent, slower,
  and outside this workflow. The bundled CSV works offline.

## Where to go next

```text
setup            installed? → spicepod → seeded dataset → running → ready → rows
 ├─ spicepod     manifest structure; runtime settings (ports, caching, telemetry)
 ├─ secrets      credentials for real sources and models: ${ secrets:KEY }, ${ env:KEY }
 ├─ connectors   one source's from: and params: (PostgreSQL, S3, Snowflake, files, ...)
 ├─ datasets     federation across sources, views, catalogs, writes
 └─ optional     acceleration / accelerators, cache, search, models / chat, sql, sdk
cookbook         a ready-made recipe instead of the user's own project
launch           the scenario deployed to Spice.ai Cloud, verified, monitored, and handed off
cloud, terraform Spice.ai Cloud resources one call at a time, or as infrastructure as code
```

After changing the spicepod (a new source, acceleration, a model), run `spice-local.sh ready` and
`verify` again: `spice run` reloads the file, and a broken change shows up as a dataset `Error`.

## Spicepod Configuration (`spicepod.yaml`)

```yaml
version: v2 # current version; v1 still loads with deprecated fields auto-migrated
kind: Spicepod
name: my_app

secrets:
  - from: env
    name: env

datasets:
  - from: <connector>:<path>
    name: <dataset_name>

models:
  - from: <provider>:<model>
    name: <model_name>
```

| Section        | Purpose                                          | Skill                    |
| -------------- | ------------------------------------------------ | ------------------------ |
| `datasets`     | Data sources for SQL queries                     | connectors, datasets     |
| `catalogs`     | External data catalog connections                | datasets                 |
| `views`        | Virtual tables from SQL queries                  | datasets                 |
| `models`       | LLMs for chat, tools, and NSQL                   | models, chat             |
| `embeddings`   | Embedding models for vector search               | search                   |
| `rerankers`    | Reranker models for the `rerank()` UDTF          | —                        |
| `tools`        | LLM function calling capabilities                | chat                     |
| `workers`      | Model load balancing and routing                 | chat                     |
| `functions`    | SQL UDFs; need `runtime.functions.enabled: true` | —                        |
| `secrets`      | Secure credential management                     | secrets                  |
| `runtime`      | Caching, query limits, telemetry, TLS, auth      | spicepod, cache          |
| `snapshots`    | Acceleration snapshot management                 | acceleration             |
| `management`   | Stream task history to Spice Cloud               | —                        |
| `metadata`     | Free-form key/value map                          | —                        |
| `dependencies` | Dependent Spicepods                              | (below)                  |

The `evals` section and `/v1/evals` were **removed in v2.0.0**. ONNX `models` and `/v1/predict` were
**removed in v2.2.0** — `models` serves LLMs only. A complete AI application manifest is in spicepod.

**Dependencies** reference other Spicepods. A basic local project needs none. Remote pod acquisition
is outside this setup workflow: do not fetch a dependency as a shortcut to populate a starter
project. Explain existing dependency declarations when asked.

## CLI Commands

| Command                   | Description                             |
| ------------------------- | --------------------------------------- |
| `spice init <name>`       | Create a directory with an empty Spicepod (add a dataset next) |
| `spice validate [path]`   | Check a Spicepod's syntax and references without starting it |
| `spice run`               | Start an already installed runtime after the prerequisite check |
| `spice sql`               | Interactive SQL REPL; `--query "<sql>"` runs one query and exits |
| `spice chat`              | Start chat REPL (requires model)        |
| `spice search`            | Perform embeddings-based search         |
| `spice add <spicepod>`    | Download a dependency (reference only; outside this workflow) |
| `spice datasets`          | List loaded datasets                    |
| `spice models`            | List loaded models                      |
| `spice catalogs`          | List loaded catalogs                    |
| `spice status`            | Show runtime status                     |
| `spice refresh <dataset>` | Refresh an accelerated dataset          |
| `spice login`             | Login to the Spice.ai Platform          |
| `spice version`           | Show CLI and runtime version (`-o json` for scripts) |
| `spice upgrade`           | Upgrade binaries (reference only; user-managed prerequisite) |

## Runtime Endpoints

| Service      | Default Address                                  | Protocol                  |
| ------------ | ------------------------------------------------ | ------------------------- |
| HTTP API     | `http://127.0.0.1:8090`                          | REST, OpenAI-compatible   |
| Arrow Flight | `127.0.0.1:50051`                                | Arrow Flight / Flight SQL |
| Metrics      | Disabled by default (`--metrics 127.0.0.1:9090`) | Prometheus `/metrics`     |

Bind addresses are runtime flags, not Spicepod keys. Keep a local development runtime on loopback.
Once the first run is green, metrics can also be enabled on loopback:

```bash
spice run --http-endpoint 127.0.0.1:8090 --flight-endpoint 127.0.0.1:50051 --metrics-endpoint 127.0.0.1:9090
```

`spiced` itself takes `--http`, `--flight`, and `--metrics`. Don't pass `--http` after `--`:
`spice run` already sets it, and `spiced` rejects the duplicate. Only expose services beyond
loopback for a user-requested deployment with authentication, TLS, and appropriate network access
controls configured; see spicepod. Do not disable those protections to make a test pass.

## HTTP API Paths

| Path                        | Description                  |
| --------------------------- | ---------------------------- |
| `POST /v1/sql`              | Execute SQL query (raw SQL body; see above) |
| `POST /v1/search`           | Embeddings-based search      |
| `POST /v1/nsql`             | Natural language to SQL      |
| `POST /v1/chat/completions` | OpenAI-compatible chat       |
| `POST /v1/embeddings`       | Generate embeddings          |
| `GET /v1/datasets`          | List datasets (`?status=true` adds each one's status and error) |
| `GET /v1/models`            | List models                  |
| `GET /health`               | Health check (process up)    |
| `GET /v1/ready`             | Readiness (`ready` once every component has loaded, else 503 `not ready`) |

Also: `POST /v1/responses`, `/v1/mcp` (MCP server), `GET /v1/status`, `GET /v1/catalogs`, `GET /v1/tools`,
and `POST /v1/datasets/{name}/acceleration/refresh`.

## Deployment Models

Spice ships as a single binary with no external dependencies: standalone (development, edge),
sidecar (low-latency access beside an application), microservice behind a load balancer, cluster
(Spice.ai Enterprise, for large data and high availability), or Spice.ai Cloud (managed, auto-scaling;
see cloud). See spicepod for sharded and tiered deployments.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `spice sql` → `show tables` lists only system tables | The spicepod has no datasets (empty `spice init`) | `spice-local.sh init <dir>`, or add a dataset |
| `/v1/ready` stays `503 not ready` | A dataset is still loading or failing | `GET /v1/datasets?status=true`; fix the dataset whose status is `Error` |
| `No data files are yet available for the dataset` | `from:` path or `file_format` matches no files | Fix the path, relative to the directory `spice run` starts in |
| `table '…' not found` | Dataset failed to load, or a different runtime answered | Check dataset status, and which process holds the port |
| `Address already in use` at startup | Another process on 8090, 50051, or the metrics port | Free ports with `--http-endpoint` / `--flight-endpoint`; don't kill what you didn't start |
| `400 Invalid JSON: missing field 'parameters'` | JSON body without `parameters` | Raw SQL body, or add `"parameters": []` |
| `argument '--http <BIND_ADDRESS>' cannot be used multiple times` | `spice run -- --http ...` | `spice run --http-endpoint ...` |
| Unknown field or variant at startup | Configuration newer than the runtime | Compare with `spice version`; use that release's docs |

## Documentation

- [Getting Started](https://spiceai.org/docs/getting-started)
- [Installation](https://spiceai.org/docs/installation)
- [Spicepod Reference](https://spiceai.org/docs/reference/spicepod)
- [CLI Reference](https://spiceai.org/docs/cli/reference)
- [API Reference](https://spiceai.org/docs/api)
