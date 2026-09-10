---
name: spice-connect-data
description: Connect Spice to data sources and query across them with federated SQL — including datasets, catalogs, views, and writes. Use this skill whenever the user wants to set up federated queries across multiple sources, create views, configure catalogs (Unity Catalog, Databricks, Iceberg), write data with INSERT INTO, or understand how Spice's query federation works. This skill focuses on the federation layer — cross-source joins, views, catalogs, and data writes. For configuring individual data source connectors (PostgreSQL params, S3 file formats, etc.), see spice-data-connector.
---

# Connect to Data Sources

Spice federates SQL queries across 30+ data sources without ETL. Connect databases, data lakes, warehouses, and APIs, then query across them with standard SQL.

## How Federation Works

Configure datasets pointing to different sources. Spice's query planner (built on Apache DataFusion) optimizes and routes queries with filter pushdown and column projection:

```yaml
datasets:
  - from: postgres:customers
    name: customers
    params:
      pg_host: db.example.com
      pg_user: ${secrets:PG_USER}
  - from: s3://bucket/orders/
    name: orders
    params:
      file_format: parquet
  - from: snowflake:analytics.sales
    name: sales
```

```sql
-- Query across all three sources in one statement
SELECT c.name, o.order_total, s.region
FROM customers c
  JOIN orders o ON c.id = o.customer_id
  JOIN sales s ON o.id = s.order_id
WHERE s.region = 'EMEA';
```

## Dataset Configuration

```yaml
datasets:
  - from: <connector>:<identifier>
    name: <dataset_name>
    params:
      # connector-specific parameters
    acceleration:
      enabled: true # optional: materialize locally (see spice-acceleration)
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
| ScyllaDB      | `scylladb:table`        | Alpha (opt-in build as of v2.3.0; see spice-data-connector) |

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

For the per-connector `from:` and `params:` reference — S3 and object storage, GitHub (including
v2.3.0 review/release/repo tables), local files, MySQL CDC, HTTP APIs, BigQuery-via-ADBC, and the
rest — see spice-data-connector. Databricks Unity Catalog catalogs accept streaming tables and views
as of v2.3.0.

## File Formats

Connectors reading from object stores (S3, ABFS) or network storage (FTP, SFTP) support:

| Format         | `file_format` | Type       |
| -------------- | ------------- | ---------- |
| Apache Parquet | `parquet`     | Structured |
| CSV            | `csv`         | Structured |
| Markdown       | `md`          | Document   |
| Text           | `txt`         | Document   |
| PDF            | `pdf`         | Document   |
| Microsoft Word | `docx`        | Document   |

Document files produce a table with `location` and `content` columns:

```yaml
datasets:
  - from: file:docs/decisions/
    name: my_documents
    params:
      file_format: md
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

- `name: foo` → `spice.public.foo`
- `name: myschema.foo` → `spice.myschema.foo`
- Use `.` to organize datasets into schemas

## Catalogs

Catalog connectors expose external data catalogs, preserving the source schema hierarchy. Tables are accessed as `<catalog>.<schema>.<table>`.

> **Note:** Only the `pg` catalog can be accelerated as a whole (v2.2.0+, Alpha). On every other
> catalog an `acceleration` block is a configuration error, not a silent no-op — accelerate an
> individual table by defining it as a dataset instead.

```yaml
catalogs:
  - from: <connector>
    name: <catalog_name>
    params:
      # connector-specific parameters
    include:
      - 'schema.*' # optional: filter with glob patterns
```

### Supported Catalogs

| Connector       | From Value      | Status |
| --------------- | --------------- | ------ |
| Unity Catalog   | `unity_catalog` | Stable |
| Databricks      | `databricks`    | Beta   |
| Iceberg         | `iceberg`       | Beta   |
| Spice.ai        | `spice.ai`      | Beta   |
| DuckLake        | `ducklake`      | Beta   |
| AWS Glue        | `glue`          | Alpha  |
| Snowflake       | `snowflake`     | Alpha  |
| PostgreSQL      | `pg`            | Beta   |
| MySQL           | `mysql`         | Alpha  |
| MS SQL Server   | `mssql`         | Alpha  |
| ADBC            | `adbc`          | Alpha  |
| Oracle          | `oracle`        | Alpha  |

### Catalog Example

```yaml
catalogs:
  - from: unity_catalog
    name: unity
    params:
      unity_catalog_endpoint: https://my-workspace.cloud.databricks.com
      databricks_token: ${ secrets:DATABRICKS_TOKEN }
    include:
      - 'my_schema.*'
```

```sql
SELECT * FROM unity.my_schema.customers LIMIT 10;
```

### PostgreSQL Catalog CDC

One block bootstraps and CDC-accelerates every table the `include` patterns match, with no per-table
config. All of them share one replication slot and publication derived from the catalog `name`, so
the WAL is decoded once for the catalog rather than once per table.

```yaml
catalogs:
  - from: pg
    name: my_pg
    include:
      - 'public.*'
    acceleration:
      engine: cayenne # optional; cayenne is the only supported engine
      refresh_mode: changes # required — no catalog-level default, and `full` is unsupported
    params:
      pg_connection_string: postgresql://${ secrets:PG_USER }:${ secrets:PG_PASS }@localhost:5432/mydb
```

Needs `wal_level = logical` and the replication privilege; Spice validates both at load and fails
fast. It also checks the server's free slots against `max_replication_slots` before creating one.
Alpha in v2.2.0: the configuration may change, and a durable catalog acceleration can come back empty
after a restart.

## Views

Views are virtual tables defined by SQL queries — useful for pre-aggregations, transformations, and simplified access:

```yaml
views:
  - name: daily_sales
    sql: |
      SELECT DATE(created_at) as date, SUM(amount) as total, COUNT(*) as orders
      FROM orders
      GROUP BY DATE(created_at)

  - name: order_details
    sql: |
      SELECT o.id, c.name as customer, p.name as product, o.quantity
      FROM orders o
      JOIN customers c ON o.customer_id = c.id
      JOIN products p ON o.product_id = p.id
```

Views can be accelerated:

```yaml
views:
  - name: rankings
    sql: |
      SELECT product_id, SUM(quantity) as total_sold
      FROM orders GROUP BY product_id ORDER BY total_sold DESC LIMIT 100
    acceleration:
      enabled: true
      refresh_check_interval: 1h
```

Views are read-only and queried like regular tables: `SELECT * FROM daily_sales`.

## Writing Data

Spice supports writing to Apache Iceberg tables and Amazon S3 Tables via `INSERT INTO`:

```yaml
datasets:
  - from: iceberg:https://catalog.example.com/v1/namespaces/sales/tables/transactions
    name: transactions
    access: read_write # required for writes
```

```sql
INSERT INTO transactions SELECT * FROM staging_transactions;
```

## Referencing Secrets

Use `${ store_name:KEY }` syntax in params. See spice-secrets for full configuration:

```yaml
params:
  pg_user: ${ env:PG_USER }
  pg_pass: ${ secrets:PG_PASSWORD }
```

## Documentation

- [Data Connectors](https://spiceai.org/docs/components/data-connectors)
- [Datasets Reference](https://spiceai.org/docs/reference/spicepod/datasets)
- [Catalogs](https://spiceai.org/docs/components/catalogs)
- [Views](https://spiceai.org/docs/features/views)
- [Query Federation](https://spiceai.org/docs/features/query-federation)
- [Data Ingestion / Writes](https://spiceai.org/docs/features/data-ingestion)
