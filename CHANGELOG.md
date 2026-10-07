# Changelog

## Unreleased

- launch: fixes from a live MySQL + PostgreSQL federation launch. `login` signs the user in to
  Spice.ai Cloud, or up, with a device code, in two steps an agent can relay (the URL and code, then
  `--wait`), so the Cloud path no longer starts with OAuth clients or tokens. OpenAI models default
  to `SCP_OPENAI_API_KEY`, the $25 OpenAI credit a new account gets as a platform-managed org
  secret. `secrets` links org secrets to the project through the Management API, including that
  unlisted one, instead of reporting them unverified, and fails on a secret it finds nowhere
  instead of letting the deploy fail on it. `local` always runs and
  queries every dataset and view, reporting components whose secrets exist only in Cloud instead of
  skipping. `deploy` stops when a federated dataset stays Initializing, deploys a paused project,
  and accepts a deployment whose record stays `in_progress` once its instance serves the new
  spicepod; `pause` stops a stuck instance from holding source connections. The lint covers
  `mysql_sslmode`, words each TLS mode accurately, and merges repeated notes. The references cover
  MySQL TLS modes, the MySQL 5.x/MariaDB metadata stall on servers with thousands of databases,
  per-dataset connection pools on shared servers, and views that wait for every dataset.
- Add project forks to cloud. `POST /v1/projects/{projectId}/forks` creates a project from another project's spicepod, connections, secrets, and runtime settings, in the same place or in another region or cluster, and `GET /v1/projects/{projectId}/forks` lists a project's forks. Project responses include `forked_from`. The skill documents the fields, the `shared_state` check before the first deployment of a fork, how a source connected to a GitHub repository is forked, and the error codes. It adds a workflow to copy or move a project to another region, `fork-project` and `list-forks` commands in `scripts/spice-cloud.sh`, and an eval.
- Add the `launch` skill: from a plain-language scenario ("serve Snowflake, Postgres, and S3 data to
  agents with OpenAI") to a Spice.ai Cloud project that is designed, deployed, verified, monitored,
  and documented. `scripts/spice-launch.sh` creates the managed project (or forks a base project to
  inherit linked org secrets), stores secrets without printing them or putting them on a command
  line, and deploys. It watches the new instance and stops early on an unresolved secret, a dataset
  stuck in Error, or a model that fails to load, instead of waiting out a rollout that stays
  `in_progress` while the old version serves. `verify` proves rows from every dataset and view, a
  model answer grounded in the data, embeddings and search, and an MCP session across several tool
  calls, and records a p50/p99 baseline. `monitors` creates the demo, POC, or production alert set in
  place, and `fire-drill` proves an alert is delivered. `handoff` writes `RUNBOOK.md` and
  `AGENT-CONNECT.md`. The skill documents what live testing found: Cloud MCP needs
  `runtime.mcp.allowed_hosts: ["*"]`, multiple replicas break MCP sessions, OpenAI SDK clients need
  `Accept-Encoding: identity` for non-streaming chat completions, org secrets reach a project only
  when linked, Cloud's schema needs search `row_id`s as lists, resizing needs private compute, and
  local or private-network sources are rejected before deploy. The skill never reads the user's
  mailbox or chat to confirm an alert; it asks them.

- Make `setup` the single entry point that takes an agent from an empty directory to a verified SQL
  result. Its Quick Start used to stop at an empty `spice init`, which `spice validate` reports as `OK`
  with zero datasets. The new `scripts/spice-local.sh` checks the existing installation, seeds a local
  dataset (a bundled 20-row CSV, or `--data` for the user's file), starts `spice run` in the background
  on free loopback ports, waits for `/v1/ready`, and verifies that each dataset is `Ready` and a query
  returns rows. It never installs software, refuses to start when the runtime is missing, detects a
  different runtime already holding port 8090, and stops only the PID it started. `verify` returns a
  ready-to-show report: directory, PID, addresses, log path, dataset status, sample rows, and why the
  ports moved when they did. The skill defines
  what counts as working, lists the anti-patterns (stopping after `spice init`, treating
  `spice validate` as proof, `pkill spiced`, metrics on the first run), and explains a failed
  user-run install whose download URL contains `/download//`.
- Document `/v1/sql` request bodies in setup, sql, cache, cookbook, and cloud: a raw SQL body works,
  while a JSON body needs `"parameters"` (`[]` when unused) and exactly `Content-Type: application/json`.
  `{"sql": "..."}` alone returns `400 Invalid JSON: missing field 'parameters'`.
- Use one secret placeholder style, `${ store:KEY }`, across datasets, secrets, cookbook, cloud, and
  terraform. The secrets skill notes that spaces inside the braces are optional.
- Make spicepod's Quick Start a credential-free local CSV, keeping PostgreSQL and OpenAI as the next
  example, and note that the `spiceai/quickstart` pod is `version: v1` and loads data from public S3.
- Add a "Verify" section to connectors and datasets: `/v1/ready`, then dataset status, then `SELECT … LIMIT 1`.
- AGENTS.md and the README lead with the skill graph from setup; the README's per-agent install details
  are collapsed under a summary table. AGENTS.md lists workflow-skill regressions to check for.
- Add the `spice-cookbook` skill, which sets up and runs recipes from the [Spice.ai cookbook](https://github.com/spiceai/cookbook). It picks a recipe by name or goal, fetches the cookbook (or a pull request or branch), and checks the runtime version, Docker, secrets, tools, and ports with `scripts/cookbook.sh` before running the README steps. The script reports whether each secret is set without printing its value.
- Fix spice-setup and spicepod-config, which set bind addresses with `spice run -- --http ...`. That fails on every v2 CLI (`argument '--http' cannot be used multiple times`) because `spice run` already passes `--http`. Use `spice run --http-endpoint`, `--flight-endpoint`, and `--metrics-endpoint` instead.
- Fix spice-search and spice-text-to-sql `rrf()` examples: the score column has been `_fused_score` since v2.0.0, not `fused_score`.

## 2.3.1

- Align plugin metadata with Spice.ai OSS runtime `v2.3.1`.
- Audit all 14 Spice skills against the v2.3.x docs ([spiceai.org/docs](https://spiceai.org/docs)), the release notes, and [docs.spice.ai](https://docs.spice.ai). Remove or replace removed and deprecated configuration, including `evals`, ONNX models, `-models` image tags, `acceleration.ready_state`, `google_api_key`, and the `/v1/apps` routes (now `/v1/projects`). Fix examples that failed to load, such as worker `type`, MCP `mcp_endpoint`, `runtime.http`, and `time_column` inside `acceleration`.
- Make the skills version-aware. Each skill has a `## Version Compatibility` section with the target release line (Spice v2.3.x, checked against v2.3.1), how to check the runtime version, and a table that maps old configuration to its replacement. Features added after v2.0.0 carry the release that shipped them.
- Add `make check-versions` (`scripts/check_versions.sh`), which keeps the plugin manifests and each skill's target release line in agreement.
- Add version-awareness evals to spice-data-connector, spice-models, and spicepod-config.
- Publishing: create GitHub Release tag `v2.3.1`; [Release Plugin](https://github.com/spiceai/skills/actions/workflows/release.yml) uploads `skills-plugin-2.3.1.zip`.

## 2.3.0

- First GitHub-versioned release aligned to Spice.ai OSS runtime `v2.3.0`.
- Plugin metadata (`.claude-plugin/plugin.json`, `marketplace.json`) set to `2.3.0`.
- Publishing: create GitHub Release tag `v2.3.0`; [Release Plugin](https://github.com/spiceai/skills/actions/workflows/release.yml) uploads `skills-plugin-2.3.0.zip`.
