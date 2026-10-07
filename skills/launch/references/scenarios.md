# From scenario to spicepod

How to turn "our data is in X, Y, and Z, and agents should use it with model M" into a
`spicepod.yaml` that deploys cleanly on Spice.ai Cloud. Written for Spice v2.3.x (checked against
v2.3.2). Every snippet uses `${ secrets:NAME }` references; `spice-launch.sh secrets` stores the
values in Cloud.

Contents:

1. [Design rules](#design-rules)
2. [Sources](#sources): PostgreSQL, Snowflake, Databricks, S3 and object stores, MySQL, others
3. [Models and tools](#models-and-tools)
4. [Search](#search)
5. [Acceleration on Spice Cloud](#acceleration-on-spice-cloud)
6. [Reachability from Spice Cloud](#reachability-from-spice-cloud)
7. [Demo stand-ins](#demo-stand-ins)
8. [A complete example](#a-complete-example)

## Design rules

- **One dataset per table agents need**, named for its meaning. Use `snake_case` names, and a
  schema prefix (`crm.accounts`) when names would collide across sources. Not every table: a
  focused set gives agents less to search through and less to get wrong.
- **A `description:` on every dataset**: what a row is, the key columns, and units. Agents read
  descriptions through the MCP `list_datasets` tool and the model's `table_schema` tool.
- **Views for the joins agents will need.** A cross-source view (Postgres orders joined to S3
  customers) turns a multi-step discovery into one query. Views are read-only and can be
  accelerated.
- **Accelerate deliberately** (see [Acceleration](#acceleration-on-spice-cloud)). Federated
  queries push filters, projections, and aggregates to the source; acceleration trades memory and
  freshness for latency.
- **Name secrets after what they unlock**: `PG_PASS`, `SNOWFLAKE_PASSWORD`, `OPENAI_API_KEY`. Spice's
  env store upper-cases keys, and Spice Cloud injects secrets as environment variables, so names
  are effectively upper case.
- **The Cloud runtime block** — always for an agent scenario:

  ```yaml
  runtime:
    mcp:
      allowed_hosts: ["*"] # else /v1/mcp answers 403 "Host header is not allowed" on Spice Cloud
    query:
      timeout: 30s # (v2.2.0+) bounds a runaway agent query; returns 504 when exceeded
  ```

  Spice Cloud configures API-key authentication itself. On a self-hosted runtime, MCP also needs
  `runtime.auth.api-key` (it returns 401 without it while `/v1/sql` stays open).

## Sources

### PostgreSQL (`postgres:schema.table`) — Stable

```yaml
datasets:
  - from: postgres:public.orders
    name: orders
    description: One row per order; amount in USD; created_at is UTC
    params:
      pg_host: db.example.com
      pg_port: "5432"
      pg_db: app
      pg_user: spice_reader
      pg_pass: ${ secrets:PG_PASS }
      pg_sslmode: verify-full # the default; needs a valid, unexpired certificate for this host
      # pg_sslrootcert: /path/or/inline/PEM for a private CA
```

- `pg_sslmode` defaults to `verify-full`. A self-signed, expired, or wrong-host certificate fails
  with `error performing TLS handshake` *before* authentication. Diagnose with
  `openssl s_client -starttls postgres -connect db.example.com:5432` (look at `Verify return code`).
  `require` encrypts without verifying: acceptable for a throwaway demo database, not production.
- A server without TLS fails under both `verify-full` and `require`; it needs `prefer` or
  `disable`, which is plaintext. Don't use that on the public internet.
- Use a dedicated read-only role. `connection_pool_size` (no `pg_` prefix) defaults to 5.
- Identifiers: `postgres:public."MixedCase"` for a case-sensitive table name.
- `refresh_mode: changes` (CDC over logical replication) needs `wal_level=logical`, a role with
  `REPLICATION`, a primary key or `REPLICA IDENTITY FULL`, and a free replication slot. "All
  replication slots are in use" is a source-side limit. Prefer `refresh_mode: full` with a
  `refresh_check_interval` unless the scenario needs second-level freshness.
- A `PG_CONNECTION_STRING` variable in the environment or `.env` silently overrides the discrete
  params; keep it out of the project directory.

### Snowflake (`snowflake:DATABASE.SCHEMA.TABLE`) — Release Candidate

```yaml
datasets:
  - from: snowflake:ANALYTICS.PUBLIC.ORDERS # UPPERCASE: the path is quoted exactly as written
    name: sf_orders
    description: Order facts from the Snowflake warehouse
    params:
      snowflake_account: myorg-myaccount
      snowflake_username: SPICE_READER
      snowflake_password: ${ secrets:SNOWFLAKE_PASSWORD }
      snowflake_warehouse: COMPUTE_WH
      snowflake_role: ANALYST
```

- Key-pair auth instead of a password: `snowflake_auth_type: keypair`, plus
  `snowflake_private_key` (the PEM, as a secret) and, if encrypted,
  `snowflake_private_key_passphrase`. Don't also set a password: a `SNOWFLAKE_PASSWORD` in the
  environment or `.env` is auto-loaded and conflicts with key-pair auth. Prefer the inline PEM
  secret over `snowflake_private_key_path`, since a Cloud instance has no key file.
- Password and key-pair are the only methods; there is no OAuth or token parameter.
- Every param needs the `snowflake_` prefix (`account:` is ignored with a warning, then the dataset
  fails). There are no database or schema params: always use the three-part path.
- Columns come back UPPERCASE, so SQL must double-quote them: `SELECT "O_TOTALPRICE" FROM sf_orders`.
  Mention that in the description so agents quote correctly, or add a view that renames columns.
- A wrong account, password, or warehouse returns only `Failed to authenticate with Snowflake`.
- Every federated query runs on the warehouse, which costs credits. For agent traffic, accelerate
  hot, small tables with `refresh_check_interval` (Snowflake has no change stream), so a stream of
  agent questions doesn't keep the warehouse awake.
- Every account can mount the sample share: `CREATE DATABASE IF NOT EXISTS SNOWFLAKE_SAMPLE_DATA
  FROM SHARE SFC_SAMPLES.SAMPLE_DATA;` then use `snowflake:SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.CUSTOMER`.
- Snowflake network policies must allow Spice Cloud's connections (see
  [Reachability](#reachability-from-spice-cloud)). PrivateLink account URLs are rejected.

### S3 and object stores (`s3://bucket/prefix/`) — Stable

```yaml
datasets:
  - from: s3://acme-lake/events/2026/
    name: events
    description: Product events, partitioned by day
    params:
      file_format: parquet # required for a prefix: parquet, csv, json, jsonl, ...
      s3_region: us-west-2 # the bucket's region; a wrong one fails with "Received redirect without LOCATION"
      s3_auth: key # public | key | iam_role
      s3_key: ${ secrets:AWS_ACCESS_KEY_ID }
      s3_secret: ${ secrets:AWS_SECRET_ACCESS_KEY }
      hive_partitioning_enabled: true # partition columns are strings: WHERE day = '2026-09-30'
```

- **Always set `s3_auth`.** Unset, the AWS default credential chain is tried first, so ambient or
  expired credentials break a public bucket (`InvalidAccessKeyId`). Use `public` for public buckets,
  and `key` with secrets for private ones. On Spice Cloud prefer `key`: `iam_role` would use
  whatever AWS identity the Cloud instance has, which your bucket policy does not grant.
- MinIO, R2, and other S3-compatible stores: `s3_endpoint: https://...` (an `http://` endpoint also
  needs `allow_http: true`) with `s3_auth: key`. The endpoint must be reachable from Spice Cloud.
- Documents (`file_format: md`, `txt`, `pdf`, `docx`, ...) load one row per file with `location` and
  `content` columns, ready for full-text or vector search.
- Also: `abfs://` (Azure), `gs://` (GCS), `delta_lake:`, and `iceberg:`; see the connectors skill.

### MySQL (`mysql:database.table`) — Stable

```yaml
datasets:
  - from: mysql:shop.orders
    name: mysql_orders
    params:
      mysql_host: mysql.example.com
      mysql_db: shop
      mysql_user: spice_reader
      mysql_pass: ${ secrets:MYSQL_PASS }
```

Native binlog CDC (`refresh_mode: changes`, v2.2.0+) needs `binlog_format=ROW`, an accelerator
with `primary_key` and an `on_conflict` upsert; see the connectors skill.

### Databricks (`databricks:catalog.schema.table`) — Stable with `mode: delta_lake`

```yaml
datasets:
  - from: databricks:main.supply.suppliers
    name: dbx_suppliers
    description: One row per supplier; s_nationkey joins the country lookup
    params:
      mode: delta_lake # Stable; the default, spark_connect, is Beta
      databricks_endpoint: dbc-1234abcd-5678.cloud.databricks.com
      databricks_token: ${ secrets:DATABRICKS_TOKEN }
      databricks_aws_access_key_id: ${ secrets:DATABRICKS_AWS_ACCESS_KEY_ID } # storage the Delta table lives in
      databricks_aws_secret_access_key: ${ secrets:DATABRICKS_AWS_SECRET_ACCESS_KEY }
      databricks_aws_region: us-east-1
```

- `delta_lake` reads the Delta files from object storage, and the documented setup supplies storage
  credentials next to the workspace token (`databricks_aws_*`, `databricks_azure_*`, or
  `databricks_google_service_account`, per cloud). `databricks_credential_vending: enabled` fetches
  short-lived storage credentials from Unity Catalog instead of static ones.
- Modes are `delta_lake`, `spark_connect` (the default, Beta), and `sql_warehouse`
  (`databricks_sql_warehouse_id`). OAuth parameters (`databricks_client_id`,
  `databricks_client_secret`, `databricks_auth_mode`) also exist. The
  [connector docs](https://spiceai.org/docs/components/data-connectors/databricks) list every
  parameter for each mode; check them against the user's cloud and auth before writing the spicepod.
- The storage and the workspace endpoint must be reachable from Spice Cloud (see
  [Reachability](#reachability-from-spice-cloud)).

### Others

BigQuery through ADBC (`adbc:` with `adbc_driver: bigquery`), DynamoDB, MongoDB, MS SQL Server,
Iceberg catalogs, Kafka, and GitHub are covered by the connectors and datasets skills and the
[connector docs](https://spiceai.org/docs/components/data-connectors). Check the connector's status
(Stable, Release Candidate, Beta, Alpha) and say it in the brief: Alpha connectors are fine for a
demo, and a risk to name in a production plan.

## Models and tools

```yaml
models:
  - from: openai:gpt-4o-mini # any OpenAI chat model id
    name: assistant # what clients pass as "model"
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
      tools: auto # unset = no tools at all
      system_prompt: |
        You answer questions about Acme's orders and customers. Use the sql tool;
        double-quote column names; say which dataset an answer came from.
```

| `tools:` | Tools the model gets |
| --- | --- |
| `auto` | `sql`, `table_schema`, `list_datasets`, `search`, `get_readiness`, `get_current_datetime` |
| `all` | `auto` + `random_sample`, `sample_distinct_columns`, `top_n_sample` |
| `nsql` | SQL and sampling tools (text-to-SQL) |
| `memory, sql` | `load_memory`, `store_memory`, `sql` (needs a `memory:store` dataset with `access: read_write`) |

- MCP clients always get the full built-in tool set, whatever a model's `tools` says.
- Every runtime start makes a small billable health-check call to each model provider. A bad key
  keeps the runtime from becoming ready; `deploy` stops on it.
- Use the unprefixed request params (`temperature`, `max_completion_tokens`, `reasoning_effort`).
  `openai_tools` is deprecated and attaches nothing.
- Other providers keep the same shape with their own prefix: `anthropic:` (`anthropic_api_key`),
  `azure:` (`azure_api_key`, `endpoint`, `azure_deployment_name`), `bedrock:`, `xai:`, and `google:`
  (Vertex AI since v2.3.0). OpenAI-compatible providers use `openai:` with `endpoint:`. The models
  skill lists their params. `anthropic:` and `xai:` are Alpha: name that in the brief.
- **Letting users choose among providers**: declare one model per provider the owner has a key for
  (`name: claude`, `openai`, `grok`), each with its own secret, and clients choose by passing the
  `name` as `model`. Spice reads a model's key from a project secret when the deployment starts;
  there is no per-request key. Declare only the providers whose keys are stored: a missing or wrong
  key keeps the whole runtime from becoming ready. `examples/spicepod.unified-data.yaml` shows the
  three-provider block, commented out until the keys exist.
- Text-to-SQL for apps: `POST /v1/nsql` with `{"query": "..."}` uses the configured model.

## Search

Full-text search needs nothing but acceleration; vector search needs an embedding model.

```yaml
embeddings:
  - from: openai:text-embedding-3-small
    name: openai_embed
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }

datasets:
  - from: s3://acme-docs/handbook/
    name: handbook
    description: Company handbook pages, one row per Markdown file
    params:
      file_format: md
      s3_auth: key
      s3_region: us-east-1
      s3_key: ${ secrets:AWS_ACCESS_KEY_ID }
      s3_secret: ${ secrets:AWS_SECRET_ACCESS_KEY }
    acceleration:
      enabled: true # required for full-text search
    columns:
      - name: content
        embeddings:
          - from: openai_embed
            row_id: [location] # a list: Spice Cloud rejects a single value when the deployment starts
            chunking:
              enabled: true
              target_chunk_size: 512
        full_text_search:
          enabled: true # required key inside the block; omitting it stops the runtime at startup
          row_id: [location]
```

- SQL: `vector_search(handbook, 'refund policy')`, `text_search(handbook, 'refund')`, and
  `rrf(...)`. The score columns are `_score` and `_fused_score`. Always add `ORDER BY _score DESC LIMIT n`.
- Agents use the MCP `search` tool; apps use `POST /v1/search` with `{"text": "...", "limit": 3}`.
- Write `row_id` as a list. `spice validate` and a local runtime accept `row_id: location`, but Spice
  Cloud checks the stored spicepod against the published schema when a deployment starts and
  answers `400 Invalid spicepod configuration`.
- Embedding columns (`content_embedding`) join the schema, so avoid `SELECT *` in prompts.
- Verify with `spice-launch.sh verify DIR --search "a phrase you know is in the data"`.

## Acceleration on Spice Cloud

| Choice | When |
| --- | --- |
| No acceleration (federated) | Large tables, data that must be live, sources that push filters well (Postgres, Snowflake) |
| `engine: arrow` (default, memory) | Small, hot tables the agents read constantly |
| `refresh_sql: SELECT ... WHERE ...` | Accelerate only the recent or relevant slice of a big table |
| `refresh_check_interval: 10m` | How stale the copy may get; unset = loaded once at startup, never refreshed |
| `refresh_mode: changes` | CDC sources (Postgres, MySQL, DynamoDB, Debezium) needing near-real-time |
| `on_zero_results: use_source` | Fall back to the source when the accelerated slice has no match |

- **Memory budget.** The default managed instance has a 4 GiB limit (check
  `spice cloud project get ORG/NAME -o json` for `resources.limits.memory`). In memory, Arrow holds
  data at several times its compressed size: 92 MiB of Parquet became about 400 MiB. Keep the
  accelerated total well under half the limit. Raising it (`spice cloud project update --memory 8Gi`)
  works only when the org has private compute (`preflight` reports `private_compute`); otherwise it
  is refused with `Resource limits can only be updated when private compute is enabled`.
- **File-mode engines** (DuckDB, SQLite, Turso, Cayenne with `mode: file`) write to disk. On Spice
  Cloud that disk survives restarts only with persistent storage (`storage_size_gb`, Enterprise);
  otherwise the file is rebuilt from the source after every restart.
- `refresh_check_interval` and `refresh_cron` together drop the dataset entirely. `refresh_mode:
  changes` on a connector without a change stream stays `Initializing` forever. `deploy` flags both.

## Reachability from Spice Cloud

A managed project runs in Spice's AWS region (`us-east-1` or `us-west-2`) and connects out over the
internet. That shapes the design:

- **Reachable**: SaaS warehouses (Snowflake, Databricks, BigQuery), public object storage, and
  databases with a public endpoint (managed Postgres or MySQL with TLS).
- **Not reachable**: `localhost`, private IPs (`10.x`, `172.16–31.x`, `192.168.x`), `*.internal`
  names, VPN-only hosts, and files on the user's machine. `deploy` rejects these before it starts.
  Options: expose a TLS endpoint with a read-only user and an IP allowlist (ask the Spice.ai team
  which addresses to allow), or keep that source on a self-hosted runtime (setup skill).
- **Pick the region nearest the data.** Cross-region federated queries add latency to every agent
  turn.

## Demo stand-ins

For a demo whose real source has no credentials yet, a public dataset can play the same role
until it does. Label it in the dataset `description` and in the report, and keep the real
`from:` in a comment so the swap is a one-line change.

| Stand-in for | Public dataset (no credentials, `s3_auth: public`, `s3_region: us-east-1`) | Size |
| --- | --- | --- |
| Customers, orders, products (warehouse or OLTP) | `s3://spiceai-demo-datasets/tpch/{customer,orders,part,supplier,nation,region}/` (Parquet) | customer 150,000 rows / 13 MB; orders 55 MB; lineitem (6M rows, 204 MB) is too big to accelerate on 4 GiB |
| Sales transactions | `s3://spiceai-demo-datasets/cleaned_sales_data.parquet` | 2,823 rows |
| Trip or event facts | `s3://spiceai-demo-datasets/taxi_trips/2024/` (Parquet) | 2.96M rows; ~400 MiB in memory |
| Documents for search | `s3://spiceai-demo-datasets/nginx/docs/` (`file_format: md`) | 94 files |
| Lookup table | `s3://spiceai-demo-datasets/taxi_zone_lookup/` (CSV) | 265 rows |

**Snowflake, Databricks, and Postgres at once**: spread the TPC-H tables so every source has a role and
the views still join. Orders stand in for Snowflake facts (1.5M rows, about 212 MiB in memory),
customers and nations for Postgres (150,000 and 25 rows), and suppliers and parts for Databricks
(10,000 and 200,000 rows). The columns are lowercase (`o_custkey`, `c_nationkey`, `s_nationkey`), and
the nation key joins all three. Together they use about 285 MiB of the 4 GiB instance. The customer-to-orders
join is the cross-source view; a country roll-up over all three takes about 30 s to initialize,
which is why `local` waits for `/v1/ready`. `examples/spicepod.unified-data.yaml` is that layout, validated and verified on Spice.ai Cloud.

```yaml
  - from: s3://spiceai-demo-datasets/tpch/customer/ # stand-in for snowflake:ANALYTICS.PUBLIC.CUSTOMERS
    name: customers
    description: "STAND-IN: public TPC-H customers until Snowflake credentials arrive"
    params:
      file_format: parquet
      s3_auth: public
      s3_region: us-east-1
    acceleration:
      enabled: true
```

## A complete example

`examples/spicepod.agents.yaml` serves Snowflake, Postgres, and S3 data to agents with an OpenAI
model, plus a cross-source view and the Cloud runtime block. Copy it, replace the hosts, tables,
and secret names with the user's, and remove sources the scenario doesn't have.
