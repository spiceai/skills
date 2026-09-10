---
name: spicepod-config
description: Create and configure Spicepod manifests (spicepod.yaml) — the central configuration file for Spice applications. Use this skill whenever the user wants to create a new spicepod.yaml from scratch, understand the overall spicepod structure and available sections, configure runtime settings (ports, caching, telemetry/observability), set up a complete Spice application combining datasets + models + search, or understand deployment models and use cases. This is the "glue" skill that shows how all Spice components fit together in one manifest. For details on specific sections (datasets, models, search, etc.), see the dedicated skills.
---

# Spicepod Configuration

A Spicepod manifest (`spicepod.yaml`) defines datasets, models, embeddings, runtime settings, and other components for a Spice application.

Spice is an open-source SQL query, search, and LLM-inference engine — not a replacement for PostgreSQL/MySQL (use those for transactional workloads) or a data warehouse (use Snowflake/Databricks for centralized analytics). Think of it as the operational data & AI layer between your applications and your data infrastructure.

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

| Section        | Purpose                            | Skill                |
| -------------- | ---------------------------------- | -------------------- |
| `datasets`     | Data sources for SQL queries       | spice-data-connector |
| `models`       | LLM/ML models for inference        | spice-models         |
| `embeddings`   | Embedding models for vector search | spice-embeddings     |
| `secrets`      | Secure credential management       | spice-secrets        |
| `catalogs`     | External data catalog connections  | spice-catalogs       |
| `views`        | Virtual tables from SQL queries    | spice-views          |
| `tools`        | LLM function calling capabilities  | spice-tools          |
| `workers`      | Model load balancing and routing   | spice-workers        |
| `runtime`      | Server ports, caching, telemetry   | (this skill)         |
| `snapshots`    | Acceleration snapshot management   | spice-accelerators   |
| `evals`        | Model evaluation definitions       | (below)              |
| `dependencies` | Dependent Spicepods                | (below)              |

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

```yaml
runtime:
  http:
    enabled: true
    port: 8090
  flight:
    enabled: true
    port: 50051
```

### CPU Entitlement

`runtime.cpu.cores` states how many cores the runtime sizes itself for — thread pools, query
partitioning, and accelerator concurrency all derive from it (v2.1.3+).

```yaml
runtime:
  cpu:
    cores: 4 # `auto` (default) detects; also `all`, or 4, 3.5, 3500m
```

Also settable as `--cpu-cores` and `SPICE_CPU_CORES`; precedence is flag > environment > Spicepod.
`auto` resolves the entitlement in order — cgroup CPU quota, then the pod's **declared**
`requests.cpu`, then the process's CPU affinity, then a one-core fallback. A CPU *share* is never an
input, only reported. **Changed in v2.2.0**: a pod with a CPU request and no CPU limit exposes no
quota, and now sizes to `min(max(2 cores, request x 2), available CPUs)` rather than every core on
the node. Set `all` to restore full-machine sizing — e.g. a `0.5`-core request that should burst on a
24-core node. `all` defers to a quantity named on a lower-precedence surface, so a platform-wide
`SPICE_CPU_CORES=all` does not silence an operator's `runtime.cpu.cores: 4`. Applied at startup only:
a Spicepod reload cannot resize the pools it sized. The effective value and its source are logged at
startup and exported as the `spiced_cpu_budget_cores` gauge.

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

Prometheus metrics: `curl http://localhost:9090/metrics`

## Evals

Evaluate model performance:

```yaml
evals:
  - name: australia
    description: Make sure the model understands Cricket.
    dataset: cricket_logic
    scorers:
      - Match
```

## Dependencies

Reference other Spicepods:

```yaml
dependencies:
  - lukekim/demo
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
spice-setup for the full command table.

## Deployment Models

Spice ships as a single ~140MB binary with no external dependencies beyond configured data sources.

| Model        | Description                                             | Best For                                    |
| ------------ | ------------------------------------------------------- | ------------------------------------------- |
| Standalone   | Single instance via Docker or binary                    | Development, edge devices, simple workloads |
| Sidecar      | Co-located with your application pod                    | Low-latency access, microservices           |
| Microservice | Multiple replicas behind a load balancer                | Heavy or varying traffic                    |
| Cluster      | Distributed multi-node deployment                       | Large-scale data, horizontal scaling        |
| Sharded      | Horizontal data partitioning across instances           | Distributed query execution                 |
| Tiered       | Sidecar for performance + shared microservice for batch | Varying requirements per component          |
| Cloud        | Fully-managed Spice.ai Cloud Platform                   | Auto-scaling, built-in observability        |

## Writing Data

Spice supports writing to Apache Iceberg tables and Amazon S3 Tables via standard `INSERT INTO`:

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
- [Getting Started](https://spiceai.org/docs/getting-started)
- [Caching](https://spiceai.org/docs/features/caching)
- [Data Acceleration](https://spiceai.org/docs/features/data-acceleration)
- [Search](https://spiceai.org/docs/features/search)
- [Observability](https://spiceai.org/docs/features/observability)
