---
name: spice-data-connector
description: Configure individual data source connectors in Spice — PostgreSQL, MySQL, S3, Databricks, Snowflake, DuckDB, GitHub, Kafka, and 25+ more. Use this skill whenever the user wants to add a dataset, connect to a specific database or data source, load data from S3 or files, configure connector-specific parameters, understand file formats (Parquet, CSV, PDF, DOCX), or set up hive partitioning. This skill is the reference for the `from:` and `params:` fields in dataset configuration. For cross-source federation, views, and catalogs, see spice-connect-data.
---

# Spice Data Connectors

Data Connectors enable federated SQL queries across databases, data warehouses, data lakes, and files. Spice connects directly to your existing data sources and provides a unified SQL interface — no ETL pipelines required. The query planner (built on Apache DataFusion) optimizes and routes queries, including filter pushdown and column projection.

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
| MySQL         | `mysql:schema.table`    | Stable (native binlog CDC)    |
| DuckDB        | `duckdb:database.table` | Stable                        |
| DynamoDB      | `dynamodb:table`        | Stable (with Streams)         |
| Azure Cosmos DB | `cosmosdb:database.container` | Release Candidate      |
| MS SQL Server | `mssql:db.table`        | Beta                          |
| MongoDB       | `mongodb:collection`    | Alpha (Change Streams)        |
| ClickHouse    | `clickhouse:db.table`   | Alpha                         |
| Oracle        | `oracle:schema.table`   | Alpha                         |
| ScyllaDB      | `scylladb:table`        | Alpha                         |

### Data Warehouses

| Connector               | From Format                       | Status            |
| ----------------------- | --------------------------------- | ----------------- |
| Databricks (Delta Lake) | `databricks:catalog.schema.table` | Stable            |
| Snowflake               | `snowflake:db.schema.table`       | Release Candidate |
| Spark                   | `spark:db.table`                  | Beta              |

### Data Lakes & Object Storage

| Connector    | From Format                  | Status            |
| ------------ | ---------------------------- | ----------------- |
| S3           | `s3://bucket/path/`          | Stable            |
| Delta Lake   | `delta_lake:/path/to/delta/` | Stable            |
| File (local) | `file:./path/to/data`        | Stable            |
| Iceberg      | `iceberg:table`              | Release Candidate (read+write) |
| DuckLake     | `ducklake:table`             | Beta              |
| Azure BlobFS | `abfs://container/path/`     | Alpha             |
| Google Cloud Storage | `gs://bucket/path/`  | Alpha             |
| AWS Glue     | `glue:db.table`              | Alpha             |

### Other Sources

| Connector    | From Format                           | Status            |
| ------------ | ------------------------------------- | ----------------- |
| Spice.ai     | `spice.ai:path/to/dataset`            | Stable            |
| Dremio       | `dremio:source.table`                 | Stable            |
| GitHub       | `github:github.com/owner/repo/issues` | Stable            |
| GraphQL      | `graphql:endpoint`                    | Release Candidate |
| ADBC         | `adbc:table`                          | Release Candidate |
| FlightSQL    | `flightsql:query`                     | Beta              |
| ODBC         | `odbc:connection`                     | Beta (Spice.ai Enterprise) |
| SharePoint   | `sharepoint:site/path`                | Beta              |
| FTP/SFTP     | `sftp://host/path/`                   | Alpha             |
| HTTP/HTTPS   | `https://url/path/data.csv`           | Alpha             |
| Kafka        | `kafka:topic`                         | Alpha             |
| Debezium CDC | `debezium:topic` (Kafka), `cdc:name` (push) | Alpha       |
| Elasticsearch | `elasticsearch:index`                | Alpha (Spice.ai Enterprise) |
| IMAP         | `imap:mailbox`                        | Alpha             |
| localpod     | `localpod:dataset`                    | Alpha             |
| SMB          | `smb://host/share/path/`              | Alpha             |
| NFS          | `nfs://host/path/`                    | Alpha (Spice.ai Enterprise) |

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

### MySQL with Native CDC

`refresh_mode: changes` streams the source's binary log (`binlog_format=ROW`) straight into the
accelerator — no Kafka, no Debezium (v2.2.0+). Spice snapshots the table, then applies committed
inserts, updates, and deletes.

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

`primary_key` and `on_conflict: upsert` are required on every upsert-capable engine (`duckdb`,
`sqlite`, `cayenne`, `postgres`, `turso`); the connector fails fast at startup without them. Only
append-only `arrow` is exempt. A file-backed accelerator persists the resume position in its
`spice_sys_mysql_binlog` sidecar, so a restart resumes rather than re-snapshotting. Delivery is
at-least-once, which the primary-key upsert absorbs. Where GTID is enabled on the source, the
position is tracked as a GTID set and survives a failover to a new primary.

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

### GitHub Issues

```yaml
datasets:
  - from: github:github.com/spiceai/spiceai/issues
    name: spiceai.issues
    params:
      github_token: ${ secrets:GITHUB_TOKEN }
    acceleration:
      enabled: true
      refresh_mode: append
      refresh_check_interval: 24h
      refresh_data_window: 14d
```

### Local File

```yaml
datasets:
  - from: file:./data/sales.parquet
    name: sales
```

### HTTP JSON API Response Cache

A dynamic JSON API dataset caches responses. Since v2.2.1 that cache is bounded per dataset —
previously it kept every response for the life of the process.

```yaml
datasets:
  - from: https://api.example.com/v1/items
    name: items
    params:
      response_cache_max_size_bytes: 16777216 # default 67108864 (64 MiB); 0 disables
      response_cache_fallback_ttl: 5m # only for an origin sending no Cache-Control at all
```

The byte value must be a whole number — `64MiB` is rejected at load. The origin's `Cache-Control`
always wins, including `no-store`, `no-cache`, and `private`, which are never retained. Structured
HTTP file datasets do not use this cache.

## File Formats

Connectors reading from object stores (S3, ABFS, GCS) or network storage (FTP, SFTP) support:

| Format         | `file_format` | Status | Type       |
| -------------- | ------------- | ------ | ---------- |
| Apache Parquet | `parquet`     | Stable | Structured |
| CSV            | `csv`         | Stable | Structured |
| Markdown       | `md`          | Stable | Document   |
| Text           | `txt`         | Stable | Document   |
| PDF            | `pdf`         | Alpha  | Document   |
| Microsoft Word | `docx`        | Alpha  | Document   |

### Document Formats

Document files (md, txt, pdf, docx) produce a table with `location` and `content` columns:

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
