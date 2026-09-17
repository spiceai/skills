---
name: spice-data-connector
description: Configure individual data source connectors in Spice — PostgreSQL, MySQL, S3, Databricks, Snowflake, DuckDB, GitHub, Kafka, and 25+ more. Use this skill whenever the user wants to add a dataset, connect to a specific database or data source, load data from S3 or files, configure connector-specific parameters, understand file formats (Parquet, CSV, PDF, DOCX), or set up hive partitioning. This skill is the reference for the `from:` and `params:` fields in dataset configuration. For cross-source federation, views, and catalogs, see spice-connect-data.
---

# Spice Data Connectors

Data Connectors enable federated SQL queries across databases, data warehouses, data lakes, and files. Spice connects directly to your existing data sources and provides a unified SQL interface — no ETL pipelines required. The query planner (built on Apache DataFusion) optimizes and routes queries, including filter pushdown and column projection.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.1). Check the user's runtime version before recommending configuration:

- **Find it**: `spice version` (CLI and runtime), `spiced --version`, or the image tag (`spiceai/spiceai:<tag>`, Helm `image.tag`). Not the runtime version: `version: v2` in `spicepod.yaml` (manifest schema) or SQL `version()` (DataFusion).
- **Markers**: unmarked content applies to v2.0.0 and later. Later additions are marked `(vX.Y.Z+)`; changes are marked **Removed**, **Deprecated**, **Changed**, or **Breaking in vX.Y.Z**.
- **Older runtime**: don't recommend a newer feature — offer `spice upgrade` or an alternative — and read that release line's docs, e.g. `https://spiceai.org/docs/v2.2/...` (`/docs/next/` tracks trunk, not a release). On v1.x, use the [v1.11 docs](https://spiceai.org/docs/v1.11) and the [v2.0 upgrade guide](https://spiceai.org/releases/v2.0-stable#upgrade-guide-from-v1x).
- **Newer runtime**: check the [release notes](https://spiceai.org/releases) for changes after v2.3.1.

| Old | Change | Use instead |
| --- | --- | --- |
| `schema_inference` dataset field | Removed in v2.2.0 (fails to load) | Delete it — inference is always on |
| Metadata columns `location`, `last_modified`, `size` | Renamed in v2.0.0 | `_location`, `_last_modified`, `_size` (document tables keep `location`, `content`) |
| ScyllaDB in the default build | Breaking in v2.3.0 | `--features scylladb` build, or Spice.ai Enterprise |
| DynamoDB `ready_lag`, `lag_exceeds_shard_retention_behavior` | Deprecated in v2.2.0 | `dynamodb_replication_ready_lag`, `dynamodb_replication_invalid_checkpoint_behavior` |
| `mongodb_num_docs_to_infer_schema` | Deprecated in v2.2.0 | `mongodb_schema_infer_max_records` |
| `pg_replication_temporary_slot` | Deprecated in v2.2.0 (ignored) | Delete it — slots are always durable |
| `csv_schema_infer_max_records`, `tsv_schema_infer_max_records` | Deprecated in v1.11 | `schema_infer_max_records` |
| `runtime.params.github_max_concurrent_connections` | Deprecated in v2.0 | `runtime.source_rate_control.github_concurrent_connections_limit` |
| `spiceai:` prefix, `spiceai_token`, `spiceai_flight_endpoint` | Legacy aliases, still accepted | `spice.ai`, `spiceai_api_key`, `spiceai_endpoint` |

## Cross-Source Federation

Datasets from different connectors are queryable in one SQL statement — a `postgres:` table joined to
an `s3://` Parquet prefix joined to a `snowflake:` table. Without acceleration, each query reads
directly from the underlying sources with filter pushdown and column projection. For the federation
model, views, and catalogs, see spice-connect-data.

## Basic Dataset Configuration

```yaml
datasets:
  - from: <connector>:<identifier>
    name: <dataset_name>
    params:
      # connector-specific parameters
    acceleration:
      enabled: true # optional: enable local materialization
```

## Supported Connectors

### Databases

| Connector     | From Format             | Status                        |
| ------------- | ----------------------- | ----------------------------- |
| PostgreSQL    | `postgres:schema.table` | Stable (native WAL CDC; also Amazon Redshift) |
| MySQL         | `mysql:schema.table`    | Stable (native binlog CDC v2.2.0+) |
| DuckDB        | `duckdb:database.schema.table` | Stable                 |
| DynamoDB      | `dynamodb:table`        | Stable (with Streams)         |
| Azure Cosmos DB | `cosmosdb:database.container` | Release Candidate      |
| MS SQL Server | `mssql:database.schema.table` | Beta                    |
| MongoDB       | `mongodb:collection`    | Alpha (Change Streams)        |
| ClickHouse    | `clickhouse:db.table`   | Alpha                         |
| Oracle        | `oracle:schema.table`   | Alpha                         |
| ScyllaDB      | `scylladb:table`        | Alpha (Spice.ai Enterprise; see below) |

### Data Warehouses

| Connector               | From Format                       | Status            |
| ----------------------- | --------------------------------- | ----------------- |
| Databricks              | `databricks:catalog.schema.table` | Stable with `mode: delta_lake`; Beta with `mode: spark_connect` (the default) |
| Snowflake               | `snowflake:DB.SCHEMA.TABLE`       | Release Candidate |
| Spark                   | `spark:db.table`                  | Beta              |

### Data Lakes & Object Storage

| Connector    | From Format                  | Status            |
| ------------ | ---------------------------- | ----------------- |
| S3           | `s3://bucket/path/`          | Stable            |
| Delta Lake   | `delta_lake:/path/to/delta/` | Stable            |
| File (local) | `file:./path/to/data`        | Stable            |
| Iceberg      | `iceberg:https://<catalog>/v1/namespaces/<ns>/tables/<table>` | Release Candidate (read+write) |
| DuckLake     | `ducklake:table`             | Beta              |
| Azure BlobFS | `abfs://container/path/`     | Alpha             |
| Google Cloud Storage | `gs://bucket/path/`  | Alpha             |
| AWS Glue     | `glue:db.table`              | Alpha             |

### Other Sources

| Connector    | From Format                           | Status            |
| ------------ | ------------------------------------- | ----------------- |
| Spice.ai     | `spice.ai/<org>/<app>/datasets/<name>` | Stable           |
| Dremio       | `dremio:source.table`                 | Stable            |
| GitHub       | `github:github.com/owner/repo/issues` | Stable            |
| Git          | `git:https://host/owner/repo.git@<ref>` | Release Candidate |
| GraphQL      | `graphql:https://host/graphql`        | Release Candidate |
| ADBC         | `adbc:table`                          | Release Candidate |
| FlightSQL    | `flightsql:catalog.schema.table`      | Beta              |
| ODBC         | `odbc:path.to.table`                  | Beta (Spice.ai Enterprise) |
| SharePoint   | `sharepoint:drive:<name>/path:/<folder>` | Beta           |
| FTP/SFTP     | `sftp://host/path/`                   | Alpha             |
| HTTP/HTTPS   | `https://url/path/data.csv`           | Alpha             |
| Kafka        | `kafka:topic`                         | Alpha             |
| Debezium CDC | `debezium:topic` (Kafka), `cdc:name` (HTTP push, v2.2.0+) | Alpha |
| Elasticsearch | `elasticsearch:index`                | Alpha (Spice.ai Enterprise) |
| IMAP         | `imap:<email_address>`                | Alpha             |
| localpod     | `localpod:dataset`                    | Alpha             |
| SMB          | `smb://host/share/path/`              | Alpha             |
| NFS          | `nfs://host/path/`                    | Alpha (Spice.ai Enterprise) |

Spice.ai Enterprise connectors are not in the default OSS build ([Distributions](https://spiceai.org/docs/reference/distributions)).

## Common Examples

### PostgreSQL

```yaml
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
```

### MySQL with Native CDC (v2.2.0+)

`refresh_mode: changes` snapshots the table, then streams committed inserts, updates, and deletes
from the binary log (`binlog_format=ROW`) into the accelerator — no Kafka, no Debezium.

```yaml
datasets:
  - from: mysql:mydb.orders
    name: orders
    params:
      mysql_host: localhost
      mysql_db: mydb
      mysql_user: replicator
      mysql_pass: ${ secrets:mysql_pass }
    acceleration:
      enabled: true
      engine: duckdb
      mode: file
      refresh_mode: changes
      primary_key: id
      on_conflict:
        id: upsert
```

`primary_key` and an `on_conflict` upsert on that key (the map above) are required on every upsert-capable engine (`duckdb`,
`sqlite`, `cayenne`, `postgres`, `turso`) — startup fails fast without them; append-only `arrow` is
exempt. A file-backed accelerator persists the resume position in its `spice_sys_mysql_binlog`
sidecar, so a restart resumes without re-snapshotting. Delivery is at-least-once (the upsert absorbs
replays). With GTID enabled on the source, the position is a GTID set that survives a failover.

### S3 with Parquet

```yaml
datasets:
  - from: s3://my-bucket/data/sales/
    name: sales
    params:
      file_format: parquet
      s3_region: us-east-1
    acceleration:
      enabled: true
      engine: duckdb
```

### GitHub Issues, Reviews, Releases (v2.3.0+)

Paths under `github:github.com/{owner}/{repo}/…` (and owner/login scoped tables). Every table returns
an `owner` column, and repository-scoped tables also return `repo`, so a multi-repo `UNION ALL` stays
separable. v2.3.0 adds:

| Path | Rows |
| --- | --- |
| `…/reviews` | One per PR review (`state`, `author`, `submitted_at`, `commit_sha`) |
| `…/review_threads` | Resolvable threads (`is_resolved`, `is_outdated`, `path`, `resolved_by`) |
| `…/releases` / `…/release_assets` | Releases and downloadable assets |
| `…/milestones` | Milestones (`due_on`, `progress_percentage`) |
| `…/repo` | One row of repository metadata |
| `github.com/{owner}/repos` | Every repository an owner has |
| `github.com/{login}/user` | Public profile for one login |

`pulls` gains draft/merge-queue/review-decision columns (e.g. `is_draft`, `mergeable`,
`review_decision`, `status_check_rollup`, `base_ref`, `head_sha`, …), and large repos no longer fail
with `Resource limits for this query exceeded`.

```yaml
datasets:
  - from: github:github.com/spiceai/spiceai/issues
    name: spiceai.issues
    params:
      github_token: ${ secrets:GITHUB_TOKEN }
      github_query_mode: search # push created_at filters to the GitHub Search API
    time_column: created_at # required by refresh_mode: append and refresh_data_window
    acceleration:
      enabled: true
      refresh_mode: append
      refresh_check_interval: 24h
      refresh_data_window: 14d

  - from: github:github.com/spiceai/spiceai/reviews
    name: spiceai.reviews
    params:
      github_token: ${ secrets:GITHUB_TOKEN }
```

### Local File

```yaml
datasets:
  - from: file:./data/sales.parquet
    name: sales
```

### HTTP JSON API Response Cache (v2.2.1+)

A dynamic JSON API dataset keeps origin responses in its own per-dataset, size-bounded cache (unbounded
before v2.2.1).

```yaml
datasets:
  - from: https://api.example.com/v1/items
    name: items
    params:
      response_cache_max_size_bytes: 16777216 # default 67108864 (64 MiB); 0 disables
      response_cache_fallback_ttl: 5m # only for an origin sending no Cache-Control at all
```

The byte value must be a whole number (`64MiB` is rejected at load). The origin's `Cache-Control`
always wins (`no-store`, `no-cache`, `private` are never retained); structured HTTP files skip it.

**ScyllaDB — Breaking in v2.3.0:** out of the default open source `spiced` build (like ODBC). Build
with `--features scylladb` / `make install-scylladb`, or use a Spice.ai Enterprise distribution. On a
build without it, a `scylladb:` dataset fails to load and names the missing feature.

**BigQuery (via ADBC):** use `from: adbc:<table>` with `adbc_driver: bigquery`. v2.3.0 runs more
shapes as one BigQuery job (temporal expressions, recursive CTEs, correlated subqueries, window
aggregates, multi-dataset same-project queries) and cancels the job when the client goes away. See
[ADBC / BigQuery](https://spiceai.org/docs/components/data-connectors/adbc).

**Databricks:** the connector accepts Unity Catalog streaming tables and views (v2.3.0+).

## File Formats

File-based connectors (S3, ABFS, GCS, HTTP/S, FTP/SFTP, SMB, NFS, local `file:`) support:

| Format         | `file_format` | Status | Type       |
| -------------- | ------------- | ------ | ---------- |
| Apache Parquet | `parquet`     | Stable | Structured |
| CSV            | `csv`         | Stable | Structured |
| JSON           | `json`        | Stable | Structured |
| Markdown       | `md`          | Stable | Document   |
| Text           | `txt`         | Stable | Document   |
| PDF            | `pdf`         | Beta   | Document   |
| Microsoft Word | `docx`        | Alpha  | Document   |

Also `tsv` and `jsonl` (see the File Formats reference), and Alpha document formats `xlsx` / `pptx`.

### Document Formats

Document files produce one row per file with `location` and `content` columns (not `_location`):

```yaml
datasets:
  - from: file:docs/decisions/
    name: my_documents
    params:
      file_format: md
```

```sql
SELECT location, content FROM my_documents LIMIT 5;
```

### Hive Partitioning

```yaml
datasets:
  - from: s3://bucket/data/
    name: partitioned_data
    params:
      file_format: parquet
      hive_partitioning_enabled: true
```

```sql
SELECT * FROM partitioned_data WHERE year = '2024' AND month = '01';
```

## Dataset Naming

- `name: foo` creates `spice.public.foo`
- `name: myschema.foo` creates `spice.myschema.foo`
- Use `.` to organize datasets into schemas

## Documentation

- [Data Connectors](https://spiceai.org/docs/components/data-connectors)
- [Datasets Reference](https://spiceai.org/docs/reference/spicepod/datasets)
- [File Formats](https://spiceai.org/docs/reference/file_format)
- [Data Accelerators](https://spiceai.org/docs/components/data-accelerators)
