---
name: spice-data-connector
description: Connect Spice to data sources like PostgreSQL, MySQL, S3, Databricks, Snowflake, and more. Use when asked to "add a dataset", "connect to a database", "load data from S3", or "configure a data source".
---

# Spice Data Connectors

Data Connectors enable federated SQL queries across databases, data warehouses, data lakes, and files.

## Basic Dataset Configuration

```yaml
datasets:
  - from: <connector>:<identifier>
    name: <dataset_name>
    params:
      # connector-specific parameters
    acceleration:
      enabled: true          # optional: enable local caching
      engine: duckdb         # arrow, duckdb, sqlite, postgres
```

## Supported Connectors

| Connector     | From Format                          | Status  |
|---------------|--------------------------------------|---------|
| PostgreSQL    | `postgres:schema.table`              | Stable  |
| MySQL         | `mysql:schema.table`                 | Stable  |
| S3            | `s3://bucket/path/`                  | Stable  |
| DuckDB        | `duckdb:database.table`              | Stable  |
| Databricks    | `databricks:catalog.schema.table`    | Stable  |
| Snowflake     | `snowflake:database.schema.table`    | Beta    |
| File          | `file:./path/to/file.parquet`        | Stable  |
| Delta Lake    | `delta_lake:/path/to/delta/`         | Stable  |
| MongoDB       | `mongodb:collection`                 | Alpha   |
| Clickhouse    | `clickhouse:database.table`          | Alpha   |

## Documentation References

Fetch these docs for connector-specific parameters and examples:

**Overview:**
- [Data Connectors Index](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/index.md)

**Database Connectors:**
- [PostgreSQL](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/postgres/index.md)
- [MySQL](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/mysql.md)
- [MS SQL Server](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/mssql.md)
- [Clickhouse](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/clickhouse.md)
- [MongoDB](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/mongodb.md)
- [DynamoDB](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/dynamodb.md)
- [Oracle](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/oracle.md)

**Cloud Data Warehouses:**
- [Snowflake](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/snowflake.md)
- [Databricks](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/databricks.md)
- [Redshift](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/redshift.md)
- [Dremio](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/dremio.md)

**Object Storage:**
- [S3](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/s3.md)
- [Azure BlobFS (ABFS)](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/abfs.md)
- [HTTP/HTTPS](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/https.md)
- [FTP/SFTP](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/ftp.md)

**File & Table Formats:**
- [Local File](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/file.md)
- [Delta Lake](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/delta-lake.md)
- [Apache Iceberg](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/iceberg.md)
- [DuckDB](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/duckdb.md)

**Other:**
- [GraphQL](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/graphql.md)
- [GitHub](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/github.md)
- [SharePoint](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/sharepoint.md)
- [Kafka](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/kafka.md)
- [Debezium CDC](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-connectors/debezium.md)

**Data Acceleration:**
- [Data Accelerators Overview](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/data-accelerators/index.md)