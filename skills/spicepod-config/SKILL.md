---
name: spicepod-config
description: Create and configure Spicepod manifests (spicepod.yaml) — the central configuration file for Spice applications. Use this skill whenever the user wants to create a new spicepod.yaml from scratch, understand the overall spicepod structure and available sections, configure runtime settings (ports, caching, telemetry/observability), set up a complete Spice application combining datasets + models + search, or understand deployment models and use cases. This is the "glue" skill that shows how all Spice components fit together in one manifest. For details on specific sections (datasets, models, search, etc.), see the dedicated skills.
---

# Spicepod Configuration

A Spicepod manifest (`spicepod.yaml`) defines datasets, models, embeddings, runtime settings, and other components for a Spice application.

Spice is an open-source SQL query, search, and LLM-inference engine — not a replacement for PostgreSQL/MySQL (use those for transactional workloads) or a data warehouse (use Snowflake/Databricks for centralized analytics). Think of it as the operational data & AI layer between your applications and your data infrastructure.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.1). Check the user's runtime version before recommending configuration:

- **Find it**: `spice version` (CLI and runtime), `spiced --version`, or the image tag (`spiceai/spiceai:<tag>`, Helm `image.tag`). Not the runtime version: `version: v2` in `spicepod.yaml` (manifest schema) or SQL `version()` (DataFusion).
- **Markers**: unmarked content applies to v2.0.0 and later. Later additions are marked `(vX.Y.Z+)`; changes are marked **Removed**, **Deprecated**, **Changed**, or **Breaking in vX.Y.Z**.
- **Older runtime**: don't recommend a newer feature — offer `spice upgrade` or an alternative — and read that release line's docs, e.g. `https://spiceai.org/docs/v2.2/...` (`/docs/next/` tracks trunk, not a release). On v1.x, use the [v1.11 docs](https://spiceai.org/docs/v1.11) and the [v2.0 upgrade guide](https://spiceai.org/releases/v2.0-stable#upgrade-guide-from-v1x).
- **Newer runtime**: check the [release notes](https://spiceai.org/releases) for changes after v2.3.1.

| Old | Change | Use instead |
| --- | --- | --- |
| `evals:` section, `/v1/evals` | Removed in v2.0.0 | Nothing — delete the section |
| `version: v1beta1` | Removed in v2.0.0 | `version: v2`; v1 field renames are under Manifest Version |
| `runtime.scheduler.partition_management.*` | Renamed in v2.0.0 (flattened) | `partition_assignment_interval`, `max_partition_assignments_per_interval`, `partition_discovery_timeout` |
| Default query memory limit of 70% | Changed in v2.0.0 (now 90%) | Set `runtime.query.memory_limit` |
| Metrics `accelerated_refresh*` | Renamed in v2.0.0 | `acceleration_refresh*` |
| Full-node CPU sizing for a pod with a CPU request and no limit | Breaking in v2.2.0 | `runtime.cpu.cores: all` |
| Browser `Origin` on `/v1/mcp` | Breaking in v2.3.1 (checked, else `403`) | List origins in `runtime.cors.allowed_origins` |

## Basic Structure

```yaml
version: v2
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

## All Sections

| Section        | Purpose                                          | Skill                                    |
| -------------- | ------------------------------------------------ | ---------------------------------------- |
| `datasets`     | Data sources for SQL queries                     | spice-data-connector, spice-connect-data |
| `catalogs`     | External data catalog connections                | spice-connect-data                       |
| `views`        | Virtual tables from SQL queries                  | spice-connect-data                       |
| `models`       | LLMs for chat, tools, and NSQL                   | spice-models, spice-ai                   |
| `embeddings`   | Embedding models for vector search               | spice-search                             |
| `rerankers`    | Reranker models for the `rerank()` UDTF          | —                                        |
| `tools`        | LLM function calling capabilities                | spice-ai                                 |
| `workers`      | Model load balancing and routing                 | spice-ai                                 |
| `functions`    | SQL UDFs; need `runtime.functions.enabled: true` | —                                        |
| `secrets`      | Secure credential management                     | spice-secrets                            |
| `runtime`      | Caching, query limits, telemetry, TLS, auth      | (this skill), spice-caching              |
| `snapshots`    | Acceleration snapshot management                 | spice-acceleration                       |
| `management`   | Stream task history to Spice Cloud               | —                                        |
| `metadata`     | Free-form key/value map                          | —                                        |
| `dependencies` | Dependent Spicepods                              | (below)                                  |

The `evals` section and `/v1/evals` were **removed in v2.0.0**. ONNX `models` and `/v1/predict` were
**removed in v2.2.0** — `models` serves LLMs only.

## Manifest Version

`v2` is the current version and what `spice init` writes. `v1` still loads and deprecated fields
auto-migrate; `v1beta1` is no longer accepted.

| v1 (deprecated)               | v2 (preferred)                    | Notes                                     |
| ----------------------------- | --------------------------------- | ----------------------------------------- |
| `runtime.results_cache`       | `runtime.caching.sql_results`     | `cache_max_size` → `max_size`             |
| `runtime.memory_limit`        | `runtime.query.memory_limit`      | v2 path wins if both are set              |
| `runtime.temp_directory`      | `runtime.query.temp_directory`    | v2 path wins if both are set              |
| `dataset.invalid_type_action` | `dataset.unsupported_type_action` | v2 adds a `string` variant                |

## Quick Start

```yaml
version: v2
kind: Spicepod
name: quickstart

secrets:
  - from: env
    name: env

datasets:
  - from: postgres:public.users
    name: users
    params:
      pg_host: localhost
      pg_port: 5432
      pg_user: ${ env:PG_USER }
      pg_pass: ${ env:PG_PASS }
    acceleration:
      enabled: true
      engine: duckdb
      refresh_check_interval: 5m

models:
  - from: openai:gpt-4o
    name: assistant
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
      tools: auto
```

## Runtime Configuration

### Server Ports

Bind addresses are runtime flags, not Spicepod keys — there is no `runtime.http`, and `runtime.flight`
has no port setting (it tunes options such as `max_message_size`). Defaults: HTTP `127.0.0.1:8090`,
Flight `127.0.0.1:50051`, Prometheus metrics disabled.

```bash
spice run -- --http 0.0.0.0:8090 --flight 0.0.0.0:50051 --metrics 0.0.0.0:9090 # same flags on spiced
```

### CPU Entitlement

`runtime.cpu.cores` sets how many cores the runtime sizes thread pools, query partitioning, and
accelerator concurrency for (v2.1.3+).

```yaml
runtime:
  cpu:
    cores: 4 # `auto` (default) detects; `all` (v2.2.0+); or 4, 3.5, 3500m
```

Also settable as `--cpu-cores` / `SPICE_CPU_CORES` (precedence: flag > environment > Spicepod); applied
at startup only. `auto` uses the cgroup CPU quota, then the pod's declared CPU request, then CPU
affinity, then one core. **Breaking in v2.2.0**: a pod with a CPU request and no CPU limit sizes to
`min(max(2 cores, request x 2), available CPUs)` instead of every core on the node. The request is read
from `SPICE_CPU_REQUEST_MILLICORES`, which the Helm chart and Kubernetes Operator set; hand-written pod
specs must add it. `all` ignores the request (a CPU limit still applies) and defers to a quantity set on
a lower-precedence surface, so a platform-wide `SPICE_CPU_CORES=all` does not override
`runtime.cpu.cores: 4`. The effective value is logged at startup and exported as
`spiced_cpu_budget_cores`. The runtime warns, without clamping, when `cores` exceeds the cgroup or
affinity CPU limit (v2.3.0+).

### Query Timeout

`runtime.query.timeout` bounds the wall-clock lifetime of a client query — planning, admission waits,
execution, and result streaming (v2.2.0+). Unset by default, meaning no timeout.

```yaml
runtime:
  query:
    timeout: 30s
```

Cancellation is cooperative, so a query can overrun slightly. Expiring before the response starts
returns HTTP `504` / gRPC `DEADLINE_EXCEEDED`; once results are streaming the stream is terminated
with an error rather than ending silently as if complete. Acceleration refreshes and health checks
are exempt. Resolved per request, so changing it alone needs no restart.

### Results Caching

```yaml
runtime:
  caching:
    sql_results:
      enabled: true
      max_size: 128MiB
      item_ttl: 1s
      eviction_policy: lru # lru or tiny_lfu
      encoding: none # none or zstd
    search_results:
      enabled: true
      max_size: 128MiB
      item_ttl: 1s
    embeddings:
      enabled: true
      max_size: 128MiB
```

### Stale-While-Revalidate

```yaml
runtime:
  caching:
    sql_results:
      item_ttl: 10s
      stale_while_revalidate_ttl: 10s
```

### Observability & Telemetry

```yaml
runtime:
  telemetry:
    enabled: true
    otel_exporter:
      endpoint: 'localhost:4317'
      push_interval: 60s
      metrics:
        - query_duration_ms
        - query_executions
```

The Prometheus endpoint is disabled by default: start the runtime with `--metrics 127.0.0.1:9090` (see
Server Ports), then `curl http://localhost:9090/metrics`.

## Dependencies

Reference other Spicepods by Spicerack slug; `spice add spiceai/quickstart` downloads the pod into
`spicepods/` and records the dependency:

```yaml
dependencies:
  - spiceai/quickstart
```

## Full AI Application Example

Datasets + embeddings + model in one manifest. The embedding column config is abbreviated here — see
spice-search for chunking and search setup, and spice-ai for `memory` and tool wiring.

```yaml
version: v2
kind: Spicepod
name: ai_app

embeddings:
  - from: openai:text-embedding-3-small
    name: embed
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }

datasets:
  - from: postgres:documents
    name: docs
    acceleration:
      enabled: true
    columns:
      - name: content
        embeddings:
          - from: embed
            row_id: id

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

## CLI Commands

`spice init`, `spice run`, `spice sql`, `spice chat`, `spice status`, `spice datasets` — see
spice-setup for the full command table. `spice validate [path]` checks a Spicepod without starting the
runtime.

## Deployment Models

Spice ships as a single ~140MB binary with no external dependencies beyond configured data sources.

| Model                         | Description                                             | Best For                                    |
| ----------------------------- | ------------------------------------------------------- | ------------------------------------------- |
| Standalone                    | Single instance via Docker or binary                    | Development, edge devices, simple workloads |
| Sidecar                       | Co-located with your application pod                    | Low-latency access, microservices           |
| Microservice                  | Multiple replicas behind a load balancer                | Heavy or varying traffic                    |
| Cluster (Spice.ai Enterprise) | Distributed multi-node deployment                       | Large-scale data, high availability         |
| Sharded                       | Independent instances per partition (e.g. customer)     | Multi-tenant isolation, load distribution   |
| Tiered                        | Sidecar for performance + shared microservice for batch | Varying requirements per component          |
| Cloud                         | Fully-managed Spice.ai Cloud Platform                   | Auto-scaling, built-in observability        |

## Writing Data

Datasets with `access: read_write` accept SQL writes on write-capable connectors: `INSERT INTO` for
Iceberg, Glue (including Amazon S3 Tables), and DuckLake; `INSERT`, `UPDATE`, and `DELETE` for
PostgreSQL, Snowflake, and DynamoDB. See spice-connect-data for per-connector details.

```yaml
datasets:
  - from: iceberg:https://catalog.example.com/v1/namespaces/sales/tables/transactions
    name: transactions
    access: read_write # required for writes
```

```sql
INSERT INTO transactions SELECT * FROM staging_transactions;
```

## Documentation

- [Spicepod Reference](https://spiceai.org/docs/reference/spicepod)
- [Datasets](https://spiceai.org/docs/reference/spicepod/datasets)
- [Runtime](https://spiceai.org/docs/reference/spicepod/runtime)
- [spiced flags](https://spiceai.org/docs/cli/reference/spiced)
- [Getting Started](https://spiceai.org/docs/getting-started)
- [Caching](https://spiceai.org/docs/features/caching)
- [Data Acceleration](https://spiceai.org/docs/features/data-acceleration)
- [Search](https://spiceai.org/docs/features/search)
- [Observability](https://spiceai.org/docs/features/observability)
