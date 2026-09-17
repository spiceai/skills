---
name: spice-accelerators
description: Choose and configure the right acceleration engine — Arrow, DuckDB, SQLite, Cayenne, PostgreSQL, or Turso. Use this skill whenever the user needs to pick an accelerator engine, compare engines (e.g. "should I use DuckDB or Cayenne?"), configure engine-specific parameters (duckdb_file, sqlite_file), tune memory vs file mode, or understand engine capabilities and limitations. This skill is the engine selection and tuning guide. For the broader acceleration feature (refresh modes, retention, snapshots, indexes), see spice-acceleration.
---

# Spice Data Accelerators

Accelerators materialize data locally from connected sources for faster queries and reduced load on source systems.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.1). Check the user's runtime version before recommending configuration:

- **Find it**: `spice version` (CLI and runtime), `spiced --version`, or the image tag (`spiceai/spiceai:<tag>`, Helm `image.tag`). Not the runtime version: `version: v2` in `spicepod.yaml` (manifest schema) or SQL `version()` (DataFusion).
- **Markers**: unmarked content applies to v2.0.0 and later. Later additions are marked `(vX.Y.Z+)`; changes are marked **Removed**, **Deprecated**, **Changed**, or **Breaking in vX.Y.Z**.
- **Older runtime**: don't recommend a newer feature — offer `spice upgrade` or an alternative — and read that release line's docs, e.g. `https://spiceai.org/docs/v2.2/...` (`/docs/next/` tracks trunk, not a release). On v1.x, use the [v1.11 docs](https://spiceai.org/docs/v1.11) and the [v2.0 upgrade guide](https://spiceai.org/releases/v2.0-stable#upgrade-guide-from-v1x).
- **Newer runtime**: check the [release notes](https://spiceai.org/releases) for changes after v2.3.1.

| Old | Change | Use instead |
| --- | --- | --- |
| `partition_by` with `engine: duckdb` (and the DuckDB partition params) | Removed in v2.2.0 | `engine: cayenne` or `arrow` |
| DuckDB `partitioned_write_flush_threshold` | Renamed in v2.0.0 (`…_rows`); removed in v2.2.0 | Cayenne or Arrow partitioning |
| `acceleration.params.cayenne_segment_cache_mb` | Deprecated in v2.2.0 (ignored) | `runtime.params.cayenne_segment_cache_mb` |
| Unset `cayenne_tuning` | Breaking in v2.2.0 (now resolves to `auto`) | `cayenne_tuning: adaptive` for the closed-loop controller |
| DuckDB v1.5 SQL and functions | Changed in v2.2.1 (bundled DuckDB is v1.4.4) | DuckDB 1.4-compatible SQL |
| `hash_index: enabled` (Arrow) | Ignored since v2.0.0 | `primary_key` |
| `turso_mvcc` | Removed in v2.0.0 (MVCC always on) | Delete it |
| `acceleration.ready_state` | Deprecated in v2.3.0 | `ready_state` on the dataset or view |

## Basic Configuration

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

## Choosing an Accelerator

| Use Case                               | Engine     | Why                                                                        |
| -------------------------------------- | ---------- | -------------------------------------------------------------------------- |
| Small datasets (<1 GB), max speed      | `arrow`    | In-memory, lowest latency                                                  |
| Small datasets (1-10 GB), complex SQL  | `duckdb`   | Mature SQL, memory management                                              |
| Datasets 10 GB and above (up to 1+ TB) | `cayenne`  | Needs 1/3 to 1/2 the memory of `duckdb`; scales beyond single-file limits  |
| Point lookups on large datasets        | `cayenne`  | Vortex: 100x faster random access vs Parquet                               |
| Simple queries, low resource usage     | `sqlite`   | Lightweight, minimal overhead                                              |
| Async operations, concurrent workloads | `turso`    | Native async, modern connection pooling                                    |
| External database integration          | `postgres` | Leverage existing PostgreSQL infra (Spice.ai Enterprise)                   |

### Cayenne vs DuckDB

Choose **Cayenne** for datasets of 10 GB or larger, tight memory headroom, multi-file ingestion (e.g. partitioned S3 data), or frequent point lookups (Vortex benchmarks: 10-20x faster scans).
Choose **DuckDB** for datasets under 10 GB, complex SQL (window functions, CTEs), existing DuckDB tooling, or explicit index control.

## Supported Engines

| Engine     | Modes                                            | Status            |
| ---------- | ------------------------------------------------ | ----------------- |
| `arrow`    | memory                                           | Stable            |
| `duckdb`   | memory, file, file_create, file_update           | Stable            |
| `cayenne`  | memory (v2.2.0+), file, file_create, file_update | Stable            |
| `sqlite`   | memory, file, file_create, file_update           | Release Candidate |
| `postgres` | N/A (attached, Spice.ai Enterprise)              | Release Candidate |
| `turso`    | memory, file, file_create, file_update           | Beta              |

`file_create` always creates a fresh acceleration file on startup, removing any existing one (snapshotted first if snapshots are enabled). `file_update` opens an existing file instead: additive schema changes (new columns only) keep it, incompatible ones (columns removed, renamed, or retyped) recreate it.

## Refresh Modes by Engine

Refresh modes (`full`, `append`, `changes`, `caching`, `snapshot`), retention, and snapshot triggers are
covered in spice-acceleration. Engine constraints to keep in mind:

- **`changes` (CDC)**: pair with a persistent accelerator (`mode: file`, or `postgres`) so a restart
  resumes instead of re-fetching. Every engine except append-only `arrow` requires `primary_key` plus an
  `on_conflict` upsert on that key (example below).
- **`caching`**: survives restarts only with `mode: file` on `duckdb`, `sqlite`, or `cayenne`.
- **`snapshot`** (Spice.ai Enterprise): needs a file-mode `duckdb`, `sqlite`, `cayenne`, or `turso` engine.

```yaml
# CDC: native Postgres logical replication or MySQL binlog (v2.2.0+), no Kafka/Debezium
acceleration:
  engine: duckdb
  mode: file
  refresh_mode: changes
  primary_key: id
  on_conflict:
    id: upsert
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
file grows on every refresh. `on_full_refresh` (v2.1.2+) chooses how that space is reclaimed:

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

**Removed in v2.2.0**: the DuckDB accelerator rejects `partition_by`. Use `cayenne` or `arrow` for a
partitioned dataset. **Changed in v2.2.1**: the bundled DuckDB is v1.4.4 (down from v1.5.5, which leaked
memory on upsert refreshes), so SQL syntax and functions added in DuckDB v1.5 are unavailable to
DuckDB-accelerated datasets.

### SQLite

```yaml
acceleration:
  engine: sqlite
  mode: file
  params:
    sqlite_file: ./data/cache.sqlite
```

### Cayenne

`mode: file` is durable. `mode: memory` (v2.2.0+) is ephemeral: it reloads from the source on restart,
doesn't support `partition_by`, and errors at a hard per-table RAM bound instead of spilling to disk
(filtered `DELETE`/`UPDATE`/`INSERT` on it apply correctly from v2.3.1). Cayenne ignores `indexes` with
a warning; deduplicate with `primary_key` + `on_conflict`.

Engine-global Cayenne settings go under `runtime.params`; setting one under `acceleration.params` has no
effect. **Deprecated in v2.2.0**: table-level `cayenne_segment_cache_mb` — Cayenne tables share one
process-wide Vortex segment cache sized by `runtime.params.cayenne_segment_cache_mb` (default 1/64 of the
memory entitlement, clamped to 256 MiB–2 GiB). **Breaking in v2.2.0**: an unset `cayenne_tuning` resolves
to `auto`; the closed-loop controller needs an explicit `cayenne_tuning: adaptive`.

The compaction memory pool is reserved only for file-mode accelerations on a small-write refresh profile,
so `refresh_mode: full` keeps the full memory limit for queries, and budgets derive from the process's
cgroup limit (v2.1.3+). Iceberg `timestamptz` columns accelerate on Cayenne from v2.1.3 and on DuckDB
from v2.1.4.

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

`auto` only ever detects anything on Linux — on every other platform it returns unknown — and there
it reads the device out of sysfs, so it also returns unknown when that lookup fails. On Linux it
detects EBS, Azure Managed Disks, EC2 instance NVMe, and `tmpfs`/`ramfs` by name, and maps NFS and
SMB/CIFS mounts to `ebs`. It does **not** recognize GCP Persistent Disk or Hyperdisk, SAN, or Ceph:
where those are exposed as non-rotational devices they resolve to `local_ssd`, which tunes for a
latency they cannot deliver, and otherwise they come back unknown. Either way the profile is wrong,
so set `storage_profile: ebs` explicitly on any network block storage outside AWS and Azure.

```yaml
acceleration:
  engine: duckdb
  mode: file
  storage_profile: ebs # amortize per-IO latency over larger flushes
  params:
    duckdb_file: /mnt/ebs/analytics.db
```

## Constraints and Indexes

`indexes` apply on `duckdb`, `sqlite`, `turso`, and `postgres`; `cayenne` ignores them. On `arrow`,
`primary_key` builds an experimental hash index (the legacy `hash_index: enabled` param is ignored).

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

Snapshots (Spice.ai Enterprise) bootstrap an acceleration file from object storage on startup, cutting
cold-start latency. They require a file-mode engine: `duckdb`, `sqlite`, `cayenne`, or `turso`. Each
snapshotted dataset must write to its own file — sharing one file across datasets is unsupported here, so
a shared `duckdb_file` and snapshots are mutually exclusive. For triggers and configuration, see
spice-acceleration.

## Memory Considerations

When using `mode: memory` (default), the dataset is loaded into RAM. Ensure sufficient memory including overhead for queries and the runtime. Mitigate with `mode: file` for duckdb, sqlite, turso, or cayenne accelerators.

## Documentation

- [Data Accelerators](https://spiceai.org/docs/components/data-accelerators)
- [Spice Cayenne](https://spiceai.org/docs/components/data-accelerators/cayenne)
- [DuckDB](https://spiceai.org/docs/components/data-accelerators/duckdb)
- [Datasets Reference](https://spiceai.org/docs/reference/spicepod/datasets)
- [Data Refresh](https://spiceai.org/docs/features/data-acceleration/data-refresh)
- [Indexes](https://spiceai.org/docs/features/data-acceleration/indexes)
- [Performance Tuning](https://spiceai.org/docs/reference/performance-tuning)
- [Memory Management](https://spiceai.org/docs/reference/memory)
