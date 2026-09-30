---
name: setup
description: Get started with an existing Spice.ai installation — check the runtime, initialize a project, run the runtime, and use the CLI. Installation and upgrade requests receive documentation guidance; this skill does not provision software. Use this skill whenever the user mentions installing Spice, setting up a new Spice project, running `spice run`, looking up CLI commands or API endpoints, deployment models, or getting started with Spice. Also use when the user asks "how do I install Spice", "how do I start Spice", "what CLI commands does Spice have", or any question about Spice runtime setup and configuration basics.
---

# Getting Started with Spice

Spice is an open-source SQL query, search, and LLM-inference engine written in Rust. It federates queries across 30+ data sources, accelerates data locally, and integrates search and AI — all configured declaratively in YAML.

Spice is **not** a replacement for PostgreSQL/MySQL (use those for transactional workloads) or a data warehouse (use Snowflake/Databricks for centralized analytics). Think of it as the operational data & AI layer between your applications and your data infrastructure.

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
missing runtime; using it to repair an incomplete installation is outside this workflow.

The CLI and runtime are separate executables. `spice run` and `spice version` resolve `spiced`
in the same order (**Changed in v2.3.0**) — `$SPICED_PATH`, then beside the running `spice`
binary, then `$HOME/.spice/bin/spiced`, then (under `sudo`) the invoking user's copy. `spice version`
is non-mutating and reports `not installed` when absent. `PATH` is not searched for the runtime.
An invalid `SPICED_PATH` is an error, not a fallback; retain a user-configured path to their existing
runtime. For an older CLI whose runtime selection differs, run the user's known installed `spiced`
binary directly rather than relying on CLI auto-install behavior. See the [run reference](https://spiceai.org/docs/cli/reference/run).

## Quick Start

Run this only after the installation check above confirms both executables are installed and
compatible. Create a local project without downloading a template or dependency pod:

```bash
spice init my_app
cd my_app
spice run
```

In another terminal:

```bash
spice sql
sql> show tables;
```

## Spicepod Configuration (`spicepod.yaml`)

The Spicepod manifest defines all components for a Spice application:

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

embeddings:
  - from: <provider>:<model>
    name: <embedding_name>
```

### All Sections

| Section        | Purpose                                          | Skill                                    |
| -------------- | ------------------------------------------------ | ---------------------------------------- |
| `datasets`     | Data sources for SQL queries                     | connectors, datasets |
| `catalogs`     | External data catalog connections                | datasets                       |
| `views`        | Virtual tables from SQL queries                  | datasets                       |
| `models`       | LLMs for chat, tools, and NSQL                   | models, chat                   |
| `embeddings`   | Embedding models for vector search               | search                             |
| `rerankers`    | Reranker models for the `rerank()` UDTF          | —                                        |
| `tools`        | LLM function calling capabilities                | chat                                 |
| `workers`      | Model load balancing and routing                 | chat                                 |
| `functions`    | SQL UDFs; need `runtime.functions.enabled: true` | —                                        |
| `secrets`      | Secure credential management                     | secrets                            |
| `runtime`      | Caching, query limits, telemetry, TLS, auth      | spicepod, cache           |
| `snapshots`    | Acceleration snapshot management                 | acceleration                       |
| `management`   | Stream task history to Spice Cloud               | —                                        |
| `metadata`     | Free-form key/value map                          | —                                        |
| `dependencies` | Dependent Spicepods                              | (below)                                  |

The `evals` section and `/v1/evals` were **removed in v2.0.0**. ONNX `models` and `/v1/predict` were
**removed in v2.2.0** — `models` serves LLMs only.

### Dependencies

The `dependencies` section references other Spicepods. A basic local project needs none.
Remote pod acquisition is outside this setup workflow: do not fetch a dependency as a shortcut
to populate a starter project. Explain existing dependency declarations when asked.

## CLI Commands

| Command                   | Description                             |
| ------------------------- | --------------------------------------- |
| `spice init <name>`       | Initialize a new Spicepod               |
| `spice run`               | Start an already installed runtime after the prerequisite check |
| `spice sql`               | Start interactive SQL REPL              |
| `spice chat`              | Start chat REPL (requires model)        |
| `spice search`            | Perform embeddings-based search         |
| `spice add <spicepod>`    | Download a dependency (reference only; outside this workflow) |
| `spice datasets`          | List loaded datasets                    |
| `spice models`            | List loaded models                      |
| `spice catalogs`          | List loaded catalogs                    |
| `spice status`            | Show runtime status                     |
| `spice refresh <dataset>` | Refresh an accelerated dataset          |
| `spice validate [path]`   | Validate a Spicepod without starting it |
| `spice login`             | Login to the Spice.ai Platform          |
| `spice version`           | Show CLI and runtime version            |
| `spice upgrade`           | Upgrade binaries (reference only; user-managed prerequisite) |

## Runtime Endpoints

| Service      | Default Address                                  | Protocol                  |
| ------------ | ------------------------------------------------ | ------------------------- |
| HTTP API     | `http://127.0.0.1:8090`                          | REST, OpenAI-compatible   |
| Arrow Flight | `127.0.0.1:50051`                                | Arrow Flight / Flight SQL |
| Metrics      | Disabled by default (`--metrics 127.0.0.1:9090`) | Prometheus `/metrics`     |

Bind addresses are runtime flags, not Spicepod keys. Keep a local development runtime on
loopback; after the installation check, metrics can also be enabled on loopback:

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
| `POST /v1/sql`              | Execute SQL query            |
| `POST /v1/search`           | Embeddings-based search      |
| `POST /v1/nsql`             | Natural language to SQL      |
| `POST /v1/chat/completions` | OpenAI-compatible chat       |
| `POST /v1/embeddings`       | Generate embeddings          |
| `GET /v1/datasets`          | List datasets                |
| `GET /v1/models`            | List models                  |
| `GET /health`               | Health check (process up)    |
| `GET /v1/ready`             | Readiness (components ready) |

Also: `POST /v1/responses`, `/v1/mcp` (MCP server), `GET /v1/status`, `GET /v1/catalogs`, `GET /v1/tools`,
and `POST /v1/datasets/{name}/acceleration/refresh`.

## Deployment Models

Spice ships as a single ~140MB binary with no external dependencies.

| Model                         | Best For                                              |
| ----------------------------- | ----------------------------------------------------- |
| Standalone                    | Development, edge devices, simple workloads           |
| Sidecar                       | Low-latency access, microservices                     |
| Microservice                  | Heavy or varying traffic behind a load balancer       |
| Cluster (Spice.ai Enterprise) | Large-scale data, high availability                   |
| Cloud                         | Auto-scaling, built-in observability (Spice.ai Cloud) |

See spicepod for sharded and tiered deployments.

## Use Cases

| Use Case                   | How Spice Helps                                                              |
| -------------------------- | ---------------------------------------------------------------------------- |
| Operational Data Lakehouse | Serve real-time workloads from Iceberg/Delta/Parquet with sub-second latency |
| Data Lake Accelerator      | Accelerate queries from seconds to milliseconds locally                      |
| Enterprise Search          | Combine semantic and full-text search across data                            |
| RAG Pipelines              | Federated data + vector search + LLMs                                        |
| Agentic AI                 | Tool-augmented LLMs with fast data access                                    |
| Real-Time Analytics        | Stream from Kafka/DynamoDB with sub-second latency                           |

## Full Example

```yaml
version: v2
kind: Spicepod
name: ai_app

secrets:
  - from: env
    name: env

embeddings:
  - from: openai:text-embedding-3-small
    name: embed
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }

datasets:
  - from: postgres:public.users
    name: users
    params:
      pg_host: localhost
      pg_user: ${ env:PG_USER }
      pg_pass: ${ env:PG_PASS }
    acceleration:
      enabled: true
      engine: duckdb
      refresh_check_interval: 5m

  - from: memory:store
    name: llm_memory
    access: read_write

models:
  - from: openai:gpt-4o
    name: assistant
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
      tools: auto, memory, search
```

## Documentation

- [Getting Started](https://spiceai.org/docs/getting-started)
- [Installation](https://spiceai.org/docs/installation)
- [Spicepod Reference](https://spiceai.org/docs/reference/spicepod)
- [CLI Reference](https://spiceai.org/docs/cli/reference)
- [API Reference](https://spiceai.org/docs/api)
