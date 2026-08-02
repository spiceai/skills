---
name: spice-accelerators
description: Choose and configure the right acceleration engine — Arrow, DuckDB, SQLite, Cayenne, PostgreSQL, or Turso. Use this skill whenever the user needs to pick an accelerator engine, compare engines (e.g. "should I use DuckDB or Cayenne?"), configure engine-specific parameters (duckdb_file, sqlite_file), tune memory vs file mode, or understand engine capabilities and limitations. This skill is the engine selection and tuning guide. For the broader acceleration feature (refresh modes, retention, snapshots, indexes), see spice-acceleration.
---

# Spice Data Accelerators

Accelerators materialize data locally from connected sources for faster queries and reduced load on source systems.

## Basic Configuration

```yaml
datasets:
  - from: postgres:my_table
    name: my_table
    acceleration:
      enabled: true
      engine: duckdb # arrow, duckdb, sqlite, cayenne, postgres, turso
      mode: memory # memory or file
      refresh_check_interval: 1h
```

## Choosing an Accelerator

| Use Case                                 | Engine     | Why                                                     |
| ---------------------------------------- | ---------- | ------------------------------------------------------- |
| Small datasets (<1 GB), max speed        | `arrow`    | In-memory, lowest latency                               |
| Medium datasets (1-100 GB), complex SQL  | `duckdb`   | Mature SQL, memory management                           |
| Large datasets (100 GB-1+ TB), analytics | `cayenne`  | Built on Vortex (Linux Foundation), 10-20x faster scans |
| Point lookups on large datasets          | `cayenne`  | 100x faster random access vs Parquet                    |
| Simple queries, low resource usage       | `sqlite`   | Lightweight, minimal overhead                           |
| Async operations, concurrent workloads   | `turso`    | Native async, modern connection pooling                 |
| External database integration            | `postgres` | Leverage existing PostgreSQL infra                      |

### Cayenne vs DuckDB

Choose **Cayenne** when datasets exceed ~1 TB, multi-file ingestion is needed, or point lookups are common.
Choose **DuckDB** when datasets are under ~1 TB, complex SQL (window functions, CTEs) is needed, or DuckDB tooling is beneficial.

## Supported Engines

| Engine     | Modes                                  | Status            |
| ---------- | -------------------------------------- | ----------------- |
| `arrow`    | memory                                 | Stable            |
| `duckdb`   | memory, file, file_create, file_update  | Stable            |
| `cayenne`  | file, file_create, file_update          | Release Candidate |
| `sqlite`   | memory, file, file_create, file_update  | Release Candidate |
| `postgres` | N/A (attached, Spice.ai Enterprise)     | Release Candidate |
| `turso`    | memory, file, file_create, file_update  | Beta              |

`file_create` always creates a fresh acceleration file on startup, removing any existing one (snapshotted first if snapshots are enabled). `file_update` opens an existing file instead: additive schema changes (new columns only) keep it, incompatible ones (columns removed, renamed, or retyped) recreate it.

## Refresh Modes

| Mode              | Description                                                    | Use Case                                  |
| ----------------- | -------------------------------------------------------------- | ----------------------------------------- |
| `full`            | Complete dataset replacement on each refresh                   | Small, slowly-changing datasets           |
| `append` (batch)  | Adds new records based on a `time_column`                      | Append-only logs, time-series data        |
| `append` (stream) | Continuous streaming without time column                       | Real-time event streams (Kafka, Debezium) |
| `changes`         | CDC from Postgres WAL, MongoDB or DynamoDB Streams, or Debezium | Frequently updated transactional data     |
| `caching`         | Request-based row-level caching                                | API responses, HTTP endpoints             |
| `snapshot`        | Reloads exclusively from the snapshot store; never queries the source | Read-only replicas fed by central snapshots |

```yaml
# Full refresh every 8 hours
acceleration:
  refresh_mode: full
  refresh_check_interval: 8h

# Append mode: check for new records from the last day every 10 minutes
acceleration:
  refresh_mode: append
  time_column: created_at
  refresh_check_interval: 10m
  refresh_data_window: 1d

# Continuous ingestion using Kafka
acceleration:
  refresh_mode: append

# CDC: native Postgres logical replication (recommended for Postgres sources)
acceleration:
  refresh_mode: changes
```

Pair `refresh_mode: changes` with a persistent accelerator (`mode: file`, or `postgres`) so a restart resumes instead of re-fetching. For the CDC source matrix and refresh-mode semantics, see spice-acceleration.

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

### With Retention Policy

Retention policies prevent unbounded growth of accelerated datasets. Spice supports time-based and custom SQL-based retention strategies:

```yaml
datasets:
  - from: postgres:events
    name: events
    time_column: created_at
    acceleration:
      enabled: true
      engine: duckdb
      retention_check_enabled: true
      retention_period: 30d
      retention_check_interval: 1h
```

### With SQL-Based Retention

```yaml
acceleration:
  retention_check_enabled: true
  retention_check_interval: 1h
  retention_sql: "DELETE FROM logs WHERE status = 'archived'"
```

### With Indexes (DuckDB, SQLite, Turso)

```yaml
acceleration:
  enabled: true
  engine: sqlite
  indexes:
    user_id: enabled
    '(created_at, status)': unique
  primary_key: id
```

## Engine-Specific Parameters

### DuckDB

```yaml
acceleration:
  engine: duckdb
  mode: file
  params:
    duckdb_file: ./data/cache.db
```

#### Bounding file growth on full refresh

A full refresh bulk-loads a fresh copy of the data, and bulk loads bypass the WAL — so DuckDB's
automatic checkpoint never fires and the blocks holding the previous copy are never returned. The
file grows on every refresh. `on_full_refresh` (v2.1.2) chooses how that space is reclaimed:

| Value             | Behavior                                                                                       | Cost                                                                    |
| ----------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `reuse_file`      | Default. Keeps writing into the current file; reclaims nothing.                                 | File grows every refresh.                                               |
| `replace_file`    | Streams into a fresh staging file, carries over other objects sharing it, checkpoints, then atomically swaps it in. | Readers never interrupted, writers pause briefly. File can shrink.      |
| `checkpoint_file` | `CHECKPOINT` in place after each refresh, escalating to `FORCE CHECKPOINT` when transactions block it. | An escalating checkpoint stalls queries on that file for a bounded window. File plateaus at its high-water mark. |

```yaml
acceleration:
  engine: duckdb
  mode: file
  refresh_mode: full
  params:
    duckdb_file: /data/shared.duckdb
    on_full_refresh: replace_file # default: reuse_file
```

Both non-default values need `mode: file` — pairing either with `mode: memory` is rejected at load
time, as is `replace_file` alongside `refresh_mode: snapshot` on the same DuckDB file, including when
a different dataset is what sets the snapshot mode. Give one of them its own `duckdb_file` instead.

### SQLite

```yaml
acceleration:
  engine: sqlite
  mode: file
  params:
    sqlite_file: ./data/cache.sqlite
```

## Storage Profile Tuning

`acceleration.storage_profile` tunes connection-pool sizing, checkpoint thresholds, and file-size
defaults for the backing medium. File-mode only (`duckdb`, `sqlite`, `turso`, `cayenne`); memory-mode
accelerators ignore it.

| Value       | When                                                        |
| ----------- | ----------------------------------------------------------- |
| `auto`      | Default. Detects the medium from the acceleration file path. |
| `local_ssd` | Local SSD/NVMe (EC2 instance store, Azure local NVMe).      |
| `ebs`       | Network block storage (Amazon EBS, Azure Managed Disks).    |
| `tmpfs`     | RAM-backed storage.                                         |

```yaml
acceleration:
  engine: duckdb
  mode: file
  storage_profile: ebs # amortize per-IO latency over larger flushes
  params:
    duckdb_file: /mnt/ebs/analytics.db
```

## Constraints and Indexes

Accelerated datasets support primary key constraints and indexes:

```yaml
acceleration:
  enabled: true
  engine: duckdb
  primary_key: order_id # Creates non-null unique index
  indexes:
    customer_id: enabled # Single column index
    '(created_at, status)': unique # Multi-column unique index
```

## Snapshots

Snapshots bootstrap an acceleration file from object storage on startup, cutting cold-start latency.
They require a file-mode engine: `duckdb`, `sqlite`, `cayenne`, or `turso`. Each snapshotted dataset
must write to its own file — sharing one file across datasets is unsupported here, so a shared
`duckdb_file` and snapshots are mutually exclusive. For triggers and configuration, see
spice-acceleration.

## Memory Considerations

When using `mode: memory` (default), the dataset is loaded into RAM. Ensure sufficient memory including overhead for queries and the runtime. Mitigate with `mode: file` for duckdb, sqlite, turso, or cayenne accelerators.

## Documentation

- [Data Accelerators](https://spiceai.org/docs/components/data-accelerators)
- [Datasets Reference](https://spiceai.org/docs/reference/spicepod/datasets)
- [Data Refresh](https://spiceai.org/docs/features/data-acceleration/data-refresh)
- [Indexes](https://spiceai.org/docs/features/data-acceleration/indexes)
- [Performance Tuning](https://spiceai.org/docs/reference/performance-tuning)
- [Memory Management](https://spiceai.org/docs/reference/memory)
