---
name: spice-acceleration
description: Accelerate data locally for sub-second query performance — the feature and its configuration. Use this skill whenever the user asks about data acceleration concepts, enabling acceleration on a dataset, choosing refresh modes (full, append, changes, caching), configuring retention policies, setting up snapshots for cold-start, adding indexes and constraints, or understanding the difference between federated and accelerated queries. This skill covers the "what and why" of acceleration. For choosing which acceleration engine to use (Arrow vs DuckDB vs SQLite vs Cayenne), see spice-accelerators.
---

# Accelerate Data

Data acceleration materializes working sets of data locally, reducing query latency from seconds to milliseconds. Hot data gets materialized for instant access while cold data remains federated.

Unlike traditional caches that store query results, Spice accelerates entire datasets with configurable refresh strategies and the flexible compute of an embedded database.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.2). Check the user's runtime version before recommending configuration:

- **Find it**: `spice version` (CLI and runtime), `spiced --version`, or the image tag (`spiceai/spiceai:<tag>`, Helm `image.tag`). Not the runtime version: `version: v2` in `spicepod.yaml` (manifest schema) or SQL `version()` (DataFusion).
- **Markers**: unmarked content applies to v2.0.0 and later. Later additions are marked `(vX.Y.Z+)`; changes are marked **Removed**, **Deprecated**, **Changed**, or **Breaking in vX.Y.Z**.
- **Older runtime**: don't recommend a newer feature — offer `spice upgrade` or an alternative — and read that release line's docs, e.g. `https://spiceai.org/docs/v2.2/...` (`/docs/next/` tracks trunk, not a release). On v1.x, use the [v1.11 docs](https://spiceai.org/docs/v1.11) and the [v2.0 upgrade guide](https://spiceai.org/releases/v2.0-stable#upgrade-guide-from-v1x).
- **Newer runtime**: check the [release notes](https://spiceai.org/releases) for changes after v2.3.2.

| Old | Change | Use instead |
| --- | --- | --- |
| `acceleration.ready_state` | Deprecated in v2.3.0 | `ready_state` on the dataset or view |
| `write_mode: write_back` with `mode: memory`, retention, a composite key, or a non-PostgreSQL source | Breaking in v2.3.0 (rejected at load) | See Durable Write-Back |
| `retention_check_enabled` without `retention_check_interval` | Changed in v2.3.0 (never ran; now logs an error) | Set `retention_check_interval` |
| `partition_by` with `engine: duckdb` | Removed in v2.2.0 | `engine: cayenne` or `arrow` |
| `hash_index: enabled` (Arrow) | Ignored since v2.0.0 | `primary_key` |
| `schema_inference` dataset field | Removed in v2.2.0 (fails to load) | Delete it — inference is always on |
| Metrics `accelerated_refresh*` | Renamed in v2.0.0 | `acceleration_refresh*` |

## Enable Acceleration

```yaml
datasets:
  - from: postgres:my_table
    name: my_table
    acceleration:
      enabled: true
      engine: duckdb # arrow (default), duckdb, sqlite, cayenne, postgres, turso
      mode: memory # memory (default) or file
      refresh_check_interval: 1h
```

## Supported Engines

| Engine     | Best for                                        | Modes                  | Status            |
| ---------- | ----------------------------------------------- | ---------------------- | ----------------- |
| `arrow`    | Small datasets (<1 GB), lowest latency          | memory                 | Stable            |
| `duckdb`   | 1-10 GB, complex SQL (window functions, CTEs)   | memory, file           | Stable            |
| `cayenne`  | 10 GB and above (up to 1+ TB), point lookups    | memory (v2.2.0+), file | Stable            |
| `sqlite`   | Simple queries, low resource usage              | memory, file           | Release Candidate |
| `turso`    | Async operations, concurrent workloads          | memory, file           | Beta              |
| `postgres` | Existing PostgreSQL infra (Spice.ai Enterprise) | N/A (attached)         | Release Candidate |

File-backed engines also accept `file_create` and `file_update` modes, plus `storage_profile` tuning. For
choosing between engines (e.g. Cayenne vs DuckDB) and engine-specific parameters, see spice-accelerators.

## Refresh Modes

| Mode              | Description                                                                          | Use Case                                    |
| ----------------- | ------------------------------------------------------------------------------------ | ------------------------------------------- |
| `full`            | Complete dataset replacement on each refresh (default)                               | Small, slowly-changing datasets             |
| `append` (batch)  | Adds rows newer than the local max of the dataset's `time_column`                    | Append-only logs, time-series data          |
| `append` (stream) | Continuous streaming without time column                                             | Real-time event streams (Kafka)             |
| `changes`         | CDC from Postgres WAL, MySQL binlog (v2.2.0+), MongoDB/DynamoDB Streams, or Debezium | Frequently updated transactional data       |
| `caching`         | Request-based row-level caching                                                      | API responses, HTTP endpoints               |
| `snapshot`        | Reloads only from the snapshot store; never queries the source (Spice.ai Enterprise) | Read-only replicas fed by central snapshots |

```yaml
# Full refresh every 8 hours
acceleration:
  refresh_mode: full
  refresh_check_interval: 8h

# Append mode: every 10 minutes, fetch rows newer than the local max(created_at), within the last day
time_column: created_at # dataset-level field; not valid inside acceleration
acceleration:
  refresh_mode: append
  refresh_check_interval: 10m
  refresh_data_window: 1d

# Continuous ingestion using Kafka
acceleration:
  refresh_mode: append

# CDC: native Postgres logical replication (recommended for Postgres sources)
acceleration:
  refresh_mode: changes
  primary_key: id
  on_conflict:
    id: upsert

# Read-only replica: reload only from the snapshot store, never from the source
acceleration:
  engine: duckdb
  mode: file
  refresh_mode: snapshot
  snapshots: enabled # or bootstrap_only
  refresh_check_interval: 30s # snapshot poll interval; defaults to 1m
```

`refresh_mode: snapshot` (Spice.ai Enterprise) also needs the top-level `snapshots` block (see Snapshots
below) and a snapshot-capable file engine (DuckDB, SQLite, Cayenne, or Turso). The runtime polls the
snapshot store at `refresh_check_interval`, validates each newer snapshot's schema, and swaps the file
atomically, so queries keep serving from the previous snapshot until the swap lands. `INSERT`, `UPDATE`,
`DELETE`, and `TRUNCATE` are rejected — the acceleration is driven entirely by snapshots.

### Request caching (`refresh_mode: caching`)

HTTP / API datasets use `refresh_mode: caching` for request-keyed row caches. Entries are keyed by
`request_path`, `request_query`, and `request_body`; a `primary_key` on those columns asserts one row per
request, so a multi-row response is refused and never cached. Bound the cache with `caching_max_size` and
`caching_max_items` (v2.3.0+) — unparseable values are refused at load rather than defaulted:

```yaml
datasets:
  - from: https://api.example.com
    name: items
    params:
      file_format: json
      allowed_request_paths: '/v1/items'
      request_query_filters: enabled
    acceleration:
      enabled: true
      engine: duckdb
      refresh_mode: caching
      params:
        caching_ttl: 5m              # default 30s; also accepted as caching_item_ttl (v2.3.0+)
        caching_max_size: 512MiB     # byte budget
        caching_max_items: 50000     # row budget
```

Eviction is entry-granular (an entry may span several rows). `caching_stale_if_error: enabled` keeps
expired entries as fallback, so nothing expires them — pair it with a size, item, or retention bound (the
runtime warns at startup otherwise). It also serves stale data when the HTTP connector returns a 429/5xx
after exhausting `max_retries` (v2.3.0+).

`acceleration.enabled: false` turns the block off rather than parking it — the dataset federates every
query — and the runtime names the settings it discards (v2.3.0+). Set `ready_state` on the dataset or
view itself. **Deprecated in v2.3.0**: `acceleration.ready_state` still applies (it overrides the
top-level key, even with `enabled: false`, so it is never listed as discarded) and warns at load,
naming the component.

A file-mode DuckDB acceleration on `refresh_mode: full` grows on every refresh unless `on_full_refresh`
(v2.1.2+) is set; see spice-accelerators for that parameter.

### CDC sources (`refresh_mode: changes`)

**PostgreSQL logical replication** (`wal_level=logical` + pgoutput) and **MySQL binlog replication**
(`binlog_format=ROW`, v2.2.0+) are native and recommended for those sources — no Kafka, no Debezium, no
external CDC infrastructure. Also native: **DynamoDB Streams** and **MongoDB Change Streams**. For a
database with no native path (SQL Server, Oracle, Db2), use **Debezium** — over Kafka (`from: debezium:…`)
or push-ingest with no Kafka bus (`from: cdc:…`, v2.2.0+), where the Debezium plugin POSTs JSON or Avro
change events to `/v1/datasets/{name}/cdc`. Kafka topics themselves use `refresh_mode: append`.

Pair CDC with a persistent accelerator (`mode: file`, or `postgres`) so a restart resumes instead of
re-fetching. Every engine except append-only `arrow` needs `primary_key` plus an `on_conflict` upsert on
that key (a map, as in the example above) — updates apply as upserts and deletes route by that key; see
spice-data-connector.

## Common Configurations

### In-Memory with Interval Refresh

```yaml
acceleration:
  enabled: true
  engine: arrow
  refresh_check_interval: 5m
```

### File-Based with Append and Time Window

```yaml
datasets:
  - from: postgres:events
    name: events
    time_column: created_at
    acceleration:
      enabled: true
      engine: duckdb
      mode: file
      refresh_mode: append
      refresh_check_interval: 1h
      refresh_data_window: 7d
```

## Retention Policies

Prevent unbounded growth of accelerated datasets with time-based or custom SQL-based retention. When
`retention_check_enabled: true`, `retention_check_interval` is required (no default); a policy missing it
runs no retention and, from v2.3.0, logs a `[retention]` error naming the dataset.

### Time-Based Retention

```yaml
datasets:
  - from: postgres:events
    name: events
    time_column: created_at # required by retention_period
    acceleration:
      enabled: true
      engine: duckdb
      retention_check_enabled: true
      retention_period: 30d
      retention_check_interval: 1h
```

### SQL-Based Retention

```yaml
acceleration:
  retention_check_enabled: true
  retention_check_interval: 1h
  retention_sql: "DELETE FROM logs WHERE status = 'archived'"
```

DuckDB evicts expired rows reliably on every check from v2.1.4, including a policy that pairs a time window
with an additional condition. Cayenne runs `retention_sql` on `full` and `changes` refreshes (not only
append) and resolves `now()` once per pass from v2.2.1; under Cayenne `mode: memory`, `retention_sql` is
ignored with a warning.

## Durable Write-Back

`acceleration.write_mode: write_back` commits a write to the accelerator, then delivers it
asynchronously to the source. Reconciling a row has to reach the source in one atomic step, so the
runtime **rejects the dataset at registration** (**Breaking in v2.3.0**) rather than accept a config
that can lose a committed write. Today only PostgreSQL can deliver it that way, and every one of these is required — the
dataset is refused at load if any is missing:

```yaml
datasets:
  - from: postgres:public.orders
    name: orders
    access: read_write       # write_mode only applies to read_write datasets
    replication:
      enabled: true          # write-back lags the source; opt in explicitly
    acceleration:
      engine: cayenne        # only Cayenne records delivery markers
      mode: file             # a recreating mode would discard undelivered writes
      write_mode: write_back
      refresh_mode: changes  # delivery is driven by the change stream
      primary_key: id        # single column; composite keys are refused
      on_conflict:
        id: upsert           # the delivery worker reconciles on this key
```

The dataset must also carry no acceleration retention (a prune could drop an acknowledged row before
it is delivered) and be the sole writer of those source rows. `INSERT`/`UPDATE` must run inside one
`BEGIN; … COMMIT;`; `DELETE`, `TRUNCATE`, and `MERGE` are rejected. Watch
`dataset_acceleration_write_back_pending_keys` — a backlog that does not drain is a delivery problem.

## Constraints and Indexes

```yaml
acceleration:
  enabled: true
  engine: duckdb
  primary_key: order_id # Creates non-null unique index
  indexes:
    customer_id: enabled # Single column index
    '(created_at, status)': unique # Multi-column unique index
```

`indexes` apply on `duckdb`, `sqlite`, `turso`, and `postgres`. **Changed in v2.3.2**: `cayenne` builds
them too, but only to speed exact-key lookups — a `unique` entry does not reject duplicates (earlier
releases ignore `indexes` on `cayenne` with a warning); see spice-accelerators. On `arrow`,
`primary_key` builds an experimental hash index (the legacy `hash_index: enabled` param is ignored).

## Snapshots

Snapshots (Spice.ai Enterprise) bootstrap file-mode accelerations (`duckdb`, `sqlite`, `cayenne`, `turso`)
on startup from object storage (S3, ADLS Gen2, GCS) or a local `file://` folder, dramatically reducing
cold-start latency in distributed deployments. Each snapshotted dataset must write to its own file.

```yaml
snapshots:
  enabled: true
  location: s3://my_bucket/snapshots/ # a URI; use file:///path for a local folder
  bootstrap_on_failure_behavior: warn # warn (default) | retry | fallback
  params:
    s3_auth: iam_role
```

Per-dataset opt-in — `acceleration.snapshots` is a string: `enabled`, `bootstrap_only`, `create_only`,
or `disabled` (default):

```yaml
acceleration:
  enabled: true
  engine: duckdb
  mode: file
  snapshots: enabled
  snapshots_trigger: refresh_complete # optional
  params:
    duckdb_file: /nvme/my_table.db
```

`snapshots_trigger` values vary by refresh mode:

- `refresh_complete`: After each refresh (default for `full` and batch `append`)
- `time_interval`: Every `snapshots_trigger_threshold` (default trigger for `changes`, streaming `append`, and `caching`, where the threshold defaults to `10m`)
- `stream_batches`: After `snapshots_trigger_threshold` batches (`changes` and streaming `append`: Kafka, Debezium, DynamoDB Streams)

## Engine-Specific Parameters

Each engine takes its own `params` — `duckdb_file`, `sqlite_file`, `on_full_refresh`, `storage_profile`, and the rest — documented in spice-accelerators.

## Memory Considerations

When using `mode: memory` (default), the dataset is loaded into RAM. Ensure sufficient memory including overhead for queries and the runtime. Use `mode: file` for duckdb, sqlite, turso, or cayenne to avoid memory pressure.

## Documentation

- [Data Acceleration](https://spiceai.org/docs/features/data-acceleration)
- [Data Accelerators](https://spiceai.org/docs/components/data-accelerators)
- [Refresh Modes](https://spiceai.org/docs/features/data-acceleration/refresh-modes)
- [Retention](https://spiceai.org/docs/features/data-acceleration/data-refresh#retention-policy)
- [Constraints](https://spiceai.org/docs/features/data-acceleration/constraints)
- [Indexes](https://spiceai.org/docs/features/data-acceleration/indexes)
- [Snapshots](https://spiceai.org/docs/features/data-acceleration/snapshots)
