---
name: spice-text-to-sql
description: Generate accurate SQL for Spice.ai's Apache DataFusion engine (PostgreSQL dialect), and build text-to-SQL workflows. Use this skill whenever the user wants to write SQL queries against Spice datasets, convert natural language to SQL, debug SQL errors, understand Spice/DataFusion data types and type casting, use Spice-specific functions (ai, embed, vector_search, text_search, rrf, JSON operators), build a text-to-SQL pipeline with schema introspection, or construct prompts for LLM-based SQL generation. Also use when the user hits SQL errors like "table not found", "cannot cast", or asks about DataFusion SQL dialect differences from PostgreSQL/MySQL.
---

# Text-to-SQL with Spice (Bring Your Own Model)

Generate accurate SQL for Spice.ai using your own LLM. This skill provides the schema introspection workflow, type reference, SQL dialect rules, and prompt template needed to produce correct queries on the first attempt — avoiding trial-and-error.

## How It Works

1. **Read `spicepod.yaml`** to know which datasets, models, embeddings, and features are configured
2. Introspect the Spice catalog to discover tables, columns, and types
3. Build a prompt containing schema, type info, and dialect rules
4. Send the prompt to your LLM to generate SQL
5. Execute the SQL — on failure, feed the error back and retry

## Step 0 — Read the Spicepod Configuration

Before generating SQL, read the application's `spicepod.yaml` to understand what is available. This tells you:

- **Which datasets exist** and their source connectors (determines what SQL features work)
- **Whether models are configured** (`models:` section) — required for `ai()` function
- **Whether embeddings are configured** (`embeddings:` section) — required for `vector_search()`
- **Whether columns have `full_text_search` enabled** — required for `text_search()`
- **Column-level `description` and `metadata`** — semantic hints that improve SQL generation
- **Whether acceleration is enabled** — JSON functions only work on accelerated (Arrow) datasets

> **Do NOT use `ai()`, `embed()`, `vector_search()`, `text_search()`, or `rrf()` unless you have confirmed they are configured in `spicepod.yaml`.** These functions require specific runtime configuration (models, embeddings, full-text indexes) and will fail at runtime if missing.

### Example spicepod.yaml inspection

```yaml
# If you see this — ai() is available with model name "main_model"
models:
  - from: openai:gpt-5
    name: main_model
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }

# If you see this — vector_search() is available using "openai_embed"
embeddings:
  - from: openai:text-embedding-3-small
    name: openai_embed
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }

datasets:
  - from: postgres:public.reviews
    name: reviews
    columns:
      - name: body
        description: 'The full text of the customer review' # semantic hint for LLMs
        embeddings:
          - from: openai_embed # enables vector_search on this column
        full_text_search:
          enabled: true # enables text_search on this column
    acceleration:
      enabled: true # required for JSON functions
```

## Step 1 — Introspect Schema

Run these queries against Spice to gather context for the prompt. This mirrors what Spice's own `/v1/nsql` endpoint does internally with its `table_schema`, `random_sample`, and `sample_distinct_columns` tools.

### List all tables

```sql
SHOW TABLES;
-- or
SELECT table_catalog, table_schema, table_name, table_type
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema');
```

### Get columns and types for a table

Spice's internal schema tool returns a markdown table with **Column, SQL Type, Arrow Type, Nullable, and Metadata** for each field. Replicate this by querying `information_schema.columns`:

```sql
SHOW COLUMNS FROM my_table;
-- or
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'my_table';
```

If your `spicepod.yaml` defines column `description` or `metadata`, include those in the prompt too — they provide semantic hints (e.g. "The full text of the customer review") that dramatically improve SQL accuracy.

### Random sample (3–5 rows to show value shapes)

> **Only sample from accelerated datasets or tables known to be small.** Sampling from large, non-accelerated federated sources (e.g. a full Snowflake table or S3 data lake) can be slow and expensive. Check `spicepod.yaml` for `acceleration.enabled: true` before sampling. For non-accelerated datasets, rely on schema + column descriptions alone.

```sql
SELECT * FROM my_table LIMIT 3;
```

### Distinct column values (shows cardinality and vocabulary)

This is a key trick from Spice's nsql implementation — for each column, sample a few distinct values so the LLM knows what values are possible.

> **Same rule: only on accelerated or known-small tables.** `SELECT DISTINCT` can trigger a full table scan on non-accelerated federated sources.

```sql
-- Per-column distinct sampling (repeat for important columns)
SELECT DISTINCT status FROM my_table LIMIT 3;
SELECT DISTINCT region FROM my_table LIMIT 3;
SELECT DISTINCT category FROM my_table LIMIT 3;
```

For high-cardinality columns (IDs, timestamps, free text), skip distinct sampling — a random sample is sufficient.

## Step 2 — Build the Prompt

Include the following sections in the system/context prompt sent to your LLM. A complete template is at the bottom of this file.

### Required context to include

| Section                 | What to include                                                              |
| ----------------------- | ---------------------------------------------------------------------------- |
| **Engine**              | "Spice.ai uses Apache DataFusion with PostgreSQL dialect"                    |
| **Schema**              | Table names, column names, SQL type, Arrow type, nullability, metadata       |
| **Column descriptions** | Semantic descriptions from spicepod.yaml `columns[].description`             |
| **Sample rows**          | 3–5 random rows per accelerated/small table (skip for large federated sources) |
| **Distinct values**      | 3 distinct values per low-cardinality column (accelerated/small tables only)   |
| **Dialect rules**       | The gotchas and rules below                                                  |
| **Available functions** | Only Spice-specific UDFs/UDTFs confirmed in spicepod.yaml                    |

## Step 3 — SQL Dialect Rules & Gotchas

Include these rules verbatim in your prompt. They prevent the most common text-to-SQL failures.

### Data types

- Spice uses **Apache Arrow types** internally. SQL types map as follows:
  - `VARCHAR`, `TEXT`, `CHAR`, `STRING` → `Utf8` (Arrow)
  - `INT` / `INTEGER` → `Int32`, `BIGINT` → `Int64`
  - `FLOAT` → `Float32`, `DOUBLE` → `Float64`
  - `BOOLEAN` → `Boolean`
  - `TIMESTAMP` → `Timestamp(Nanosecond, None)` — **nanosecond precision, no timezone**
  - `DATE` → `Date32`
  - `DECIMAL(p, s)` → `Decimal128` (p ≤ 38) or `Decimal256` (p > 38)
- **No UUID, BLOB, CLOB, DATETIME, ENUM, SET, ARRAY (SQL), NVARCHAR types.** If source data has these, they are typically mapped to `Utf8` or `Binary`.
- Use `arrow_typeof(expr)` to inspect the actual Arrow type of any expression.

### Casting

- Use `CAST(x AS type)` or the PostgreSQL shorthand `x::type`.
- Cast timestamps explicitly when comparing: `WHERE created_at > '2024-01-01'::TIMESTAMP`.
- When casting to `DECIMAL`, always specify precision and scale: `CAST(x AS DECIMAL(10,2))`.

### Timestamps & dates

- `now()` returns `Timestamp(Nanosecond)`.
- Use `INTERVAL` for relative time: `now() - INTERVAL '7 days'`.
- Extract parts with `date_part('year', ts)` or `extract(YEAR FROM ts)`.
- `date_trunc('month', ts)` truncates to the start of the period.
- **No `DATEADD` / `DATEDIFF`** — use arithmetic with `INTERVAL` or `date_part`.
- For Unix timestamps, use `to_unixtime(ts)` (returns seconds as Float64) or `to_timestamp(epoch_secs)`.
- `to_timestamp_millis(ms)`, `to_timestamp_micros(us)`, `to_timestamp_nanos(ns)` for other precisions.

### String functions

- Use `||` for concatenation (not `CONCAT` with `+`). `concat(a, b)` and `concat_ws(sep, a, b)` also work.
- `LIKE` is case-sensitive. For case-insensitive matching use `ILIKE` or `lower(col) LIKE lower(pattern)`.
- **No `~` or `!~` regex operators.** Use `regexp_like(col, pattern)`, `regexp_match(col, pattern)`, `regexp_replace(col, pattern, replacement)`.
- `length(s)` returns character count; `octet_length(s)` returns byte count.
- `trim()`, `ltrim()`, `rtrim()`, `btrim()` for whitespace removal.
- `split_part(string, delimiter, index)` — index is **1-based**.
- `starts_with(s, prefix)`, `ends_with(s, suffix)` return boolean.

### Aggregation & grouping

- **Every non-aggregated column in SELECT must appear in GROUP BY** (no implicit grouping).
- Use `FILTER (WHERE condition)` to conditionally aggregate: `count(*) FILTER (WHERE status = 'active')`.
- `BOOL_AND(expr)` / `BOOL_OR(expr)` for boolean aggregation.
- `STRING_AGG(expr, delimiter)` to concatenate strings within groups.
- `ARRAY_AGG(expr)` collects values into an array.

### NULLs

- Use `IS NULL` / `IS NOT NULL` (never `= NULL`).
- `COALESCE(a, b, ...)` returns the first non-NULL argument.
- `NULLIF(a, b)` returns NULL if `a = b`.
- NULL propagates through most operations — be explicit with `COALESCE` when needed.

### Identifiers

- Use **double quotes** for identifiers with special characters or reserved words: `"order"`, `"group"`.
- String literals use **single quotes**: `'hello'`.
- Spice dataset naming: `name: foo` → fully qualified as `spice.public.foo`. You can also just use `foo`.

### Subqueries & CTEs

- CTEs (`WITH ... AS`) are supported and preferred for readability.
- Correlated subqueries in `WHERE` and `HAVING` are supported.
- `EXISTS`, `IN`, `NOT IN`, `ANY`, `ALL` subquery operators work.

### JOINs

- Standard `INNER`, `LEFT`, `RIGHT`, `FULL OUTER`, `CROSS` joins are supported.
- **No `LATERAL` joins** — use correlated subqueries or CTEs instead.
- When joining datasets from different connectors (federated queries), Spice handles cross-source joins transparently.

### Window functions

- Supported: `ROW_NUMBER()`, `RANK()`, `DENSE_RANK()`, `LAG()`, `LEAD()`, `FIRST_VALUE()`, `LAST_VALUE()`, `NTH_VALUE()`, `NTILE()`.
- All aggregate functions work with `OVER (PARTITION BY ... ORDER BY ...)`.
- `QUALIFY` clause is supported for filtering window function results.

### LIMIT & ordering

- `LIMIT n` and `OFFSET n` are supported.
- `ORDER BY` supports `ASC/DESC` and `NULLS FIRST/LAST`.

### Unsupported SQL features

- **No stored procedures, triggers, or user-defined functions via SQL.**
- **No `CREATE INDEX`** — search indexes are configured in `spicepod.yaml`.
- **No `UPDATE` or `DELETE`** — only `INSERT INTO` is supported for DML.
- **No `MERGE` / `UPSERT`.**
- **No `PIVOT` / `UNPIVOT`** — use `CASE WHEN` with aggregation instead.
- **No `LATERAL` join.**

## Spice-Specific Functions

Include relevant function signatures in your prompt **only when confirmed available** via `spicepod.yaml`.

### AI functions (requires `models:` in spicepod.yaml)

```sql
-- Text generation — use the model name from spicepod.yaml
SELECT ai('Summarize this: ' || content) AS summary FROM docs;
SELECT ai('Classify: ' || text, 'gpt-5') AS label FROM reviews;

-- Embeddings — requires `embeddings:` in spicepod.yaml
SELECT embed('hello world', 'my_embed_model') AS vec;
```

### Search UDTFs (requires embeddings and/or full_text_search configured on dataset columns)

```sql
-- Vector (semantic) search — requires column with `embeddings:` config
SELECT id, score FROM vector_search(my_table, 'search query')
ORDER BY score DESC LIMIT 10;

-- Full-text (keyword) search — requires `full_text_search: enabled: true` on column
SELECT id, score FROM text_search(my_table, 'keywords', body_column)
ORDER BY score DESC LIMIT 10;

-- Hybrid search (Reciprocal Rank Fusion) — requires both above
SELECT id, fused_score FROM rrf(
  vector_search(my_table, 'semantic query'),
  text_search(my_table, 'keyword query', content),
  join_key => 'id'
) ORDER BY fused_score DESC LIMIT 10;
```

### JSON functions

Spice includes `datafusion-functions-json` for querying JSON stored as strings:

```sql
-- Extract values
SELECT json_get_str(metadata, 'name') AS name FROM items;
SELECT json_get_int(payload, 'count') AS cnt FROM events;

-- Operators (-> returns json value, ->> returns text)
SELECT metadata->>'color' AS color FROM products;
SELECT metadata->'nested'->'key' FROM products;

-- Check key existence
SELECT * FROM items WHERE metadata ? 'status';
-- or
SELECT * FROM items WHERE json_contains(metadata, 'status');
```

> **Note:** JSON functions only work during DataFusion (Arrow) execution. They may not work on federated sources that do not accelerate locally.

### Spark-compatible functions

Spice includes `datafusion-functions-spark`: `array()`, `bit_get()`, `date_add()`, `like()`, `parse_url()`, and others following [Spark SQL semantics](https://spark.apache.org/docs/latest/api/sql/index.html).

## Error Recovery (Retry with Feedback)

Spice's `/v1/nsql` endpoint retries up to 10 times when generated SQL fails. It feeds back the failed query and error message so the model avoids repeating the same mistake. Use the same pattern:

```
The following SQL query failed. Fix it.

sql: `SELECT * FROM "spice.public.orders" LIMIT 1`
error: `Error during planning: table 'spice.public.spice.public.orders' not found`

Do not repeat the same mistake. Return only corrected SQL.
```

Common mistakes the model makes (and the fix to include in retry context):

- **Double-qualifying table names**: `"catalog.schema.table"` instead of `"catalog"."schema"."table"` — tables with schemas and catalogs use separate quoted identifiers
- **Using unsupported syntax**: `LATERAL`, `~`, `DATEADD` — reference the dialect rules
- **Wrong column names**: the model hallucinated a column — re-include the schema

## Prompt Template

Use this template when sending schema + question to your LLM. Replace placeholders with actual introspected data. Only include the search/AI sections if confirmed in `spicepod.yaml`.

```
You are a SQL expert. Generate a single SQL query for Apache DataFusion (PostgreSQL dialect) running in Spice.ai.

## Rules
- DataFusion SQL, PostgreSQL dialect. No MySQL or T-SQL syntax.
- Use CAST(x AS type) or x::type for type conversion.
- Timestamps are Timestamp(Nanosecond, None). Use INTERVAL for date math (e.g. now() - INTERVAL '7 days').
- No DATEADD/DATEDIFF. No ~ regex operator — use regexp_like(). LIKE is case-sensitive; use ILIKE for case-insensitive.
- String concat: || or concat(). Split: split_part(s, delim, 1-based-index).
- No UPDATE, DELETE, MERGE, PIVOT, LATERAL, stored procedures.
- INSERT INTO is the only DML.
- Every non-aggregated SELECT column must be in GROUP BY.
- Use COALESCE for NULL-safe defaults. Use IS NULL, never = NULL.
- Double-quote reserved-word identifiers. Single-quote string literals.
- For tables with schemas and catalogs: '"catalog"."schema"."table"' NOT '"catalog.schema.table"'.
- Columns with capitals must be quoted.
- Window functions: ROW_NUMBER(), RANK(), LAG(), LEAD(), etc. with OVER().
- QUALIFY clause is supported.
- JSON: use ->> for text extraction, -> for nested access, json_get_str/int/float/bool for typed access.
{%- if has_search %}
- vector_search(table, 'query') for semantic search. text_search(table, 'query', column) for keyword search.
- rrf(vector_search(...), text_search(...), join_key => 'id') for hybrid search.
{%- endif %}
{%- if has_ai %}
- ai('prompt') or ai('prompt', 'model_name') for LLM text generation in SQL.
{%- endif %}

## Schema
{schema}

## Column Descriptions
{column_descriptions}

## Sample Data
{sample_rows}

## Distinct Values
{distinct_values}

{%- if failed_attempts %}
## Previous Failed Attempts
Avoid repeating these mistakes:
{failed_attempts}
{%- endif %}

## Question
{user_question}

Respond with ONLY the SQL query. No explanation.
```

## Example Workflow

````python
import openai

# 0. Read spicepod.yaml to know what's configured (models, embeddings, search)
#    This determines which functions are available in prompts.

# 1. Introspect schema (via Spice SDK or Flight SQL)
schema_info = spice_client.query("""
  SELECT table_name, column_name, data_type, is_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public'
""")

# 2. Random sample (as Spice's nsql does internally)
sample = spice_client.query("SELECT * FROM orders LIMIT 3")

# 3. Distinct values for key columns (as Spice's nsql does internally)
distinct_status = spice_client.query("SELECT DISTINCT status FROM orders LIMIT 3")

# 4. Build prompt with schema + sample + distinct values
prompt = f"""You are a SQL expert. Generate a single SQL query for Apache DataFusion (PostgreSQL dialect) running in Spice.ai.

## Rules
- DataFusion SQL, PostgreSQL dialect.
- Timestamps are Timestamp(Nanosecond, None). Use INTERVAL for date math.
- No DATEADD/DATEDIFF. Use regexp_like() not ~. LIKE is case-sensitive; use ILIKE for insensitive.
- Every non-aggregated SELECT column must be in GROUP BY.
- No UPDATE, DELETE, MERGE, PIVOT, LATERAL.
- For tables with schemas: '"catalog"."schema"."table"' NOT '"catalog.schema.table"'.
- Columns with capitals must be quoted.

## Schema
{schema_info}

## Sample Data
{sample}

## Distinct Values
status: {distinct_status}

## Question
{user_question}

Respond with ONLY the SQL query."""

# 5. Generate SQL
response = openai.chat.completions.create(
    model="gpt-5",
    messages=[{"role": "user", "content": prompt}],
    temperature=0
)
sql = response.choices[0].message.content.strip().removeprefix("```sql").removesuffix("```").strip()

# 6. Execute — on failure, retry with error feedback (up to N retries)
for attempt in range(3):
    try:
        result = spice_client.query(sql)
        break
    except Exception as e:
        sql = retry_with_error_feedback(prompt, sql, str(e))
````

## Troubleshooting

| Error                                      | Cause                           | Fix                                                                    |
| ------------------------------------------ | ------------------------------- | ---------------------------------------------------------------------- |
| `column X must appear in GROUP BY`         | Non-aggregated column in SELECT | Add missing column to GROUP BY or wrap in aggregate                    |
| `Cannot cast Utf8 to Timestamp`            | Implicit cast failed            | Use explicit `CAST('...' AS TIMESTAMP)` or `::TIMESTAMP`               |
| `This feature is not implemented: LATERAL` | Unsupported syntax              | Rewrite with correlated subquery or CTE                                |
| `No function matches regex_operator ~`     | Wrong regex syntax              | Use `regexp_like(col, pattern)`                                        |
| `Table not found`                          | Wrong name or schema            | Check with `SHOW TABLES`. Use fully qualified `schema.table` if needed |
| `Arrow error: Cast error`                  | Type mismatch in operation      | Check types with `arrow_typeof()`, add explicit CAST                   |
| `JSON function not supported`              | Querying federated source       | Accelerate the dataset locally (`acceleration.enabled: true`)          |
| `ai() function not found`                  | No model configured             | Add `models:` section to spicepod.yaml                                 |
| `vector_search: no embedding column`       | No embeddings on column         | Add `embeddings:` to the column in spicepod.yaml                       |
| `text_search: column not indexed`          | Full-text search not enabled    | Add `full_text_search: enabled: true` to column config                 |

## Documentation

- [Spice SQL Reference](https://spiceai.org/docs/reference/sql)
- [DataFusion SQL Reference](https://datafusion.apache.org/user-guide/sql/index.html)
- [Spice Data Types](https://spiceai.org/docs/reference/datatypes)
- [AI Functions](https://spiceai.org/docs/reference/sql/ai)
- [Search Functions](https://spiceai.org/docs/reference/sql/search)
- [JSON Functions](https://spiceai.org/docs/reference/sql/json)
- [Scalar Functions](https://spiceai.org/docs/reference/sql/scalar_functions)
- [Aggregate Functions](https://spiceai.org/docs/reference/sql/aggregate_functions)
