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

| Engine     | Mode           | Status            |
| ---------- | -------------- | ----------------- |
| `arrow`    | memory         | Stable            |
| `duckdb`   | memory, file   | Stable            |
| `sqlite`   | memory, file   | Release Candidate |
| `cayenne`  | file           | Beta              |
| `postgres` | N/A (attached) | Release Candidate |
| `turso`    | memory, file   | Beta              |

## Refresh Modes

| Mode              | Description                                                    | Use Case                                  |
| ----------------- | -------------------------------------------------------------- | ----------------------------------------- |
| `full`            | Complete dataset replacement on each refresh                   | Small, slowly-changing datasets           |
| `append` (batch)  | Adds new records based on a `time_column`                      | Append-only logs, time-series data        |
| `append` (stream) | Continuous streaming without time column                       | Real-time event streams (Kafka, Debezium) |
| `changes`         | CDC-based incremental updates via Debezium or DynamoDB Streams | Frequently updated transactional data     |
| `caching`         | Request-based row-level caching                                | API responses, HTTP endpoints             |

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

# CDC with Debezium or DynamoDB Streams
acceleration:
  refresh_mode: changes
```

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

### SQLite

```yaml
acceleration:
  engine: sqlite
  mode: file
  params:
    sqlite_file: ./data/cache.sqlite
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

## Snapshots (DuckDB, SQLite & Cayenne file mode)

Bootstrap file-based accelerations from S3 or filesystem snapshots on startup. This dramatically reduces cold-start latency in distributed deployments.

Snapshot triggers vary by refresh mode:

- `refresh_complete`: Creates snapshots after each refresh (full and batch-append modes)
- `time_interval`: Creates snapshots on a fixed schedule (all refresh modes)
- `stream_batches`: Creates snapshots after every N batches (streaming modes: Kafka, Debezium, DynamoDB Streams)

```yaml
snapshots:
  enabled: true
  location: s3://my_bucket/snapshots/
  bootstrap_on_failure_behavior: warn # warn | retry | fallback
  params:
    s3_auth: iam_role
```

Per-dataset opt-in:

```yaml
acceleration:
  enabled: true
  engine: duckdb
  mode: file
  snapshots:
    enabled: true
```

## Memory Considerations

When using `mode: memory` (default), the dataset is loaded into RAM. Ensure sufficient memory including overhead for queries and the runtime. Mitigate with `mode: file` for duckdb, sqlite, turso, or cayenne accelerators.

## Documentation

- [Data Accelerators](https://spiceai.org/docs/components/data-accelerators)
- [Datasets Reference](https://spiceai.org/docs/reference/spicepod/datasets)
- [Data Refresh](https://spiceai.org/docs/features/data-acceleration/data-refresh)
- [Indexes](https://spiceai.org/docs/features/data-acceleration/indexes)
- [Performance Tuning](https://spiceai.org/docs/reference/performance-tuning)
- [Memory Management](https://spiceai.org/docs/reference/memory)
