---
name: spice-caching
description: Configure Spice.ai in-memory result caching for SQL queries, search results, and embeddings. Use this skill whenever the user asks about caching configuration, tuning cache TTL or max size, choosing eviction policies (LRU vs TinyLFU), enabling stale-while-revalidate, setting up cache-control headers, using custom cache keys (Spice-Cache-Key), monitoring cache metrics, choosing between plan vs SQL cache key types, or enabling zstd compression for cached results. Also use when the user asks why they're getting MISS/STALE responses or wants to optimize cache hit rates.
---

# Spice Caching

Configure in-memory caching for SQL query results, search results, and embeddings in the Spice runtime.

## Overview

Spice caches results from SQL queries (`/v1/sql`), search (`/v1/search`), and embeddings requests. All three caches are **enabled by default** with a 1-second TTL and 128 MiB max size. Caching applies to HTTP and Arrow Flight APIs.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.1). Check the user's runtime version before recommending configuration:

- **Find it**: `spice version` (CLI and runtime), `spiced --version`, or the image tag (`spiceai/spiceai:<tag>`, Helm `image.tag`). Not the runtime version: `version: v2` in `spicepod.yaml` (manifest schema) or SQL `version()` (DataFusion).
- **Markers**: unmarked content applies to v2.0.0 and later. Later additions are marked `(vX.Y.Z+)`; changes are marked **Removed**, **Deprecated**, **Changed**, or **Breaking in vX.Y.Z**.
- **Older runtime**: don't recommend a newer feature — offer `spice upgrade` or an alternative — and read that release line's docs, e.g. `https://spiceai.org/docs/v2.2/...` (`/docs/next/` tracks trunk, not a release). On v1.x, use the [v1.11 docs](https://spiceai.org/docs/v1.11) and the [v2.0 upgrade guide](https://spiceai.org/releases/v2.0-stable#upgrade-guide-from-v1x).
- **Newer runtime**: check the [release notes](https://spiceai.org/releases) for changes after v2.3.1.

| Old | Change | Use instead |
| --- | --- | --- |
| `runtime.results_cache` (`cache_max_size`) | Deprecated in v1.4.0 (auto-migrates) | `runtime.caching.sql_results` (`max_size`) |
| `engine: pingora` on an OSS build | Changed in v2.2.0 (Enterprise only; falls back to Moka) | `engine: moka` (default) |
| Caching-accelerator storage created before v2.0.0 | Breaking in v2.0.0 (errors at startup) | Delete the accelerator file before upgrading |
| Refresh or DML write evicting cached results | Changed in v2.3.0 when `stale_while_revalidate_ttl` is set (served `STALE`) | Leave the TTL unset or `0s` to keep eviction |
| Unlabeled `*_cache_evictions` | Changed in v2.1.5 (`reason` label) | Aggregate by `reason` |

## Configuration

Caching is configured under `runtime.caching` in `spicepod.yaml`:

```yaml
version: v2
kind: Spicepod
name: app

runtime:
  caching:
    sql_results:
      enabled: true
      max_size: 1GiB # Default 128MiB
      item_ttl: 1m # Default 1s
      eviction_policy: lru # lru | tiny_lfu
      hashing_algorithm: xxh3
      cache_key_type: plan # plan | sql
      encoding: none # none | zstd
      stale_while_revalidate_ttl: 30s # Default 0s (disabled)
    search_results:
      enabled: true
      max_size: 1GiB
      item_ttl: 1m
      eviction_policy: lru
    embeddings:
      enabled: true
      max_size: 128MiB
      item_ttl: 1m
```

## Common Parameters (All Cache Types)

| Parameter           | Default  | Description                                                                           |
| ------------------- | -------- | ------------------------------------------------------------------------------------- |
| `enabled`           | `true`   | Enable/disable the cache                                                              |
| `max_size`          | `128MiB` | Maximum cache size                                                                    |
| `eviction_policy`   | `lru`    | `lru` (Least Recently Used) or `tiny_lfu` (higher hit rate for skewed access)         |
| `item_ttl`          | `1s`     | Cache entry TTL (Time to Live)                                                        |
| `hashing_algorithm` | `xxh3`   | Hash for cache keys: `xxh3`, `ahash`, `siphash`, `blake3`, `xxh32`, `xxh64`, `xxh128` |
| `engine`            | `moka`   | `moka`, or `pingora` on Spice.ai Enterprise. **Breaking in v2.2.0**: OSS builds log a warning and fall back to Moka |

## SQL Results Extra Parameters

| Parameter                    | Default | Description                                                                                                        |
| ---------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------ |
| `cache_key_type`             | `plan`  | `plan` = logical plan (matches semantically equivalent queries); `sql` = raw SQL string (faster, exact match only) |
| `encoding`                   | `none`  | `none` or `zstd` (compresses cached results, 50-90% reduction)                                                     |
| `stale_while_revalidate_ttl` | `0s`    | Serve stale entries while refreshing in background. `0s` = disabled                                                |

## Choosing Parameters

### `cache_key_type`

- **`plan`** (default): Matches semantically equivalent queries even with different SQL syntax. Requires query parsing overhead.
- **`sql`**: Faster lookups, exact string match. Avoid with dynamic functions like `NOW()`.

### `eviction_policy`

- **`lru`** (default): Good general-purpose policy.
- **`tiny_lfu`**: Better hit rate when some queries are accessed much more frequently than others.

### `encoding`

- **`none`** (default): Zero compression overhead, uses more memory.
- **`zstd`**: High compression (50-90% reduction) with fast decompression. Use for large result sets.

### `hashing_algorithm`

- **`xxh3`** (default): Fastest general-purpose.
- **`ahash`** / **`xxh64`** / **`xxh128`**: Lower collision probability for many cached queries.
- **`blake3`**: Cryptographic security required.
- **`siphash`**: Protection against hash-flooding DoS attacks.

## Stale-While-Revalidate

When `stale_while_revalidate_ttl` is set to a non-zero value:

1. Cache entries are served normally until `item_ttl` expires.
2. After `item_ttl` expires but before `item_ttl + stale_while_revalidate_ttl`, the stale entry is served immediately with `STALE` status.
3. A background task refreshes the cache entry.
4. After `item_ttl + stale_while_revalidate_ttl`, the entry is evicted.

```yaml
runtime:
  caching:
    sql_results:
      enabled: true
      item_ttl: 10s
      stale_while_revalidate_ttl: 10s
      # Fresh for 10s → Stale (served while refreshing) for 10s → Evicted
```

> **Conflict warning**: When using `refresh_mode: caching` on a dataset, do not configure both `runtime.caching.sql_results.stale_while_revalidate_ttl` and `acceleration.params.caching_stale_while_revalidate_ttl` for the same dataset. Choose one approach.

### Stale across acceleration refresh (v2.3.0+)

With a non-zero `stale_while_revalidate_ttl`, an acceleration refresh or DML write **marks** dependent
SQL results-cache entries stale instead of evicting them. Inside the window — measured from the change,
but never past `item_ttl + stale_while_revalidate_ttl` after the entry was stored — the previous result
is served with `Results-Cache-Status: STALE` while one background revalidation runs per key; past it,
the request is a miss. With no window (unset or `0s`), invalidation evicts, as it did before v2.3.0.

For dataset-level `refresh_mode: caching` size/count bounds (`caching_max_size`, `caching_max_items`,
v2.3.0+), see spice-acceleration.

## Cache Control Headers

### HTTP API

Use the standard `Cache-Control` header with `/v1/sql` and `/v1/search`:

| Directive          | Description                                                       |
| ------------------ | ----------------------------------------------------------------- |
| `no-cache`         | Skip cache for this request; cache the result for future requests |
| `min-fresh=N`      | Require cached entry to remain fresh for at least N seconds       |
| `max-stale=N`      | Accept stale responses up to N seconds old                        |
| `only-if-cached`   | Return only cached responses; error on cache miss                 |

```bash
# Skip cache for this query
curl -H "cache-control: no-cache" -XPOST http://localhost:8090/v1/sql -d 'SELECT 1'

# Only accept fresh results (at least 30s remaining)
curl -H "cache-control: min-fresh=30" -XPOST http://localhost:8090/v1/sql -d 'SELECT 1'

# Accept stale up to 60s
curl -H "cache-control: max-stale=60" -XPOST http://localhost:8090/v1/sql -d 'SELECT 1'

# Only return if cached
curl -H "cache-control: only-if-cached" -XPOST http://localhost:8090/v1/sql -d 'SELECT 1'
```

### Spice CLI

`--cache-control` takes only `cache` (default) or `no-cache` — `spice sql` silently treats any other
value as `cache`, and `spice search` rejects it. Send `min-fresh`, `max-stale`, or `only-if-cached` as
an HTTP or Flight header instead.

```bash
spice sql --cache-control no-cache
spice search --cache-control no-cache
```

### Arrow FlightSQL

Set `cache-control` in request metadata:

```rust
let mut request = FlightDescriptor::new_cmd(sql_command_bytes).into_request();
request.metadata_mut().insert("cache-control", "no-cache");
```

JDBC:

```java
Properties props = new Properties();
props.setProperty("cache-control", "no-cache");
Connection conn = DriverManager.getConnection("jdbc:arrow-flight-sql://localhost:50051", props);
```

## Custom Cache Keys

Set the `Spice-Cache-Key` header to share cache entries across semantically equivalent but syntactically different queries. Valid keys: up to 128 alphanumeric characters plus `-` and `_`. Custom keys take precedence over `cache_key_type`.

```bash
# First query — cache MISS
curl -XPOST http://localhost:8090/v1/sql \
  -H "spice-cache-key: users_spiceai" \
  -d "select * from users where org_id = 1;"

# Different query, same cache key — cache HIT
curl -XPOST http://localhost:8090/v1/sql \
  -H "spice-cache-key: users_spiceai" \
  -d "select * from users where split_part(email, '@', 2) = 'spice.ai';"
```

> **Warning**: Ensure queries sharing a cache key are truly semantically equivalent. The runtime will return the cached result regardless of the actual query.

## Response Headers

Responses include a header indicating cache status:

| Cache Type       | Response Header               |
| ---------------- | ----------------------------- |
| `sql_results`    | `Results-Cache-Status`        |
| `search_results` | `Search-Results-Cache-Status` |

| Status     | Meaning                                              |
| ---------- | ---------------------------------------------------- |
| `HIT`      | Served from cache                                    |
| `MISS`     | Cache checked, result not found                      |
| `BYPASS`   | Cache bypassed (e.g., `cache-control: no-cache`)     |
| `STALE`    | Stale entry served while revalidating                |
| _(absent)_ | Cache did not apply (disabled or system table query) |

## Monitoring / Metrics

Cache metrics are available at the Prometheus-compatible metrics endpoint. Prefix by cache type: `results_*`, `search_results_*`, `embeddings_*`.

| Metric                   | Type    | Description               |
| ------------------------ | ------- | ------------------------- |
| `*_cache_max_size_bytes` | Gauge   | Configured max cache size |
| `*_cache_requests`       | Counter | Total cache lookups       |
| `*_cache_hits`           | Counter | Total cache hits          |
| `*_cache_misses`         | Counter | Total cache misses        |
| `*_cache_items_count`    | Gauge   | Current items in cache    |
| `*_cache_size_bytes`     | Gauge   | Current cache size        |
| `*_cache_evictions`      | Counter | Entries removed, by `reason` (v2.1.5+) |
| `*_cache_hit_ratio`      | Gauge   | Hit ratio (hits / total)  |

The `reason` label is `size` (over `max_size`), `expired` (past `item_ttl`), or `invalidated` (a
refresh or DML write dropped entries that read a table); alert on `size` and `expired` for real cache
pressure. `results_cache_stale_rejections` (v2.1.5+) counts lookups that refused an entry because a
table it read had changed; they are also counted in `results_cache_misses`. With a non-zero
`stale_while_revalidate_ttl`, refreshes mark entries stale instead of evicting them, so watch
`results_cache_table_invalidations{mode="evict"|"mark_stale"}` and
`results_cache_swr_revalidations{outcome}` (v2.3.0+). Counters export as zero from startup (v2.1.5+).

## Common Recipes

### High-throughput Dashboard (Maximize Hit Rate)

```yaml
runtime:
  caching:
    sql_results:
      item_ttl: 30s
      max_size: 2GiB
      eviction_policy: tiny_lfu
      encoding: zstd
      stale_while_revalidate_ttl: 30s
```

### Low-Latency API (Exact Queries, Fast Lookups)

```yaml
runtime:
  caching:
    sql_results:
      item_ttl: 5s
      cache_key_type: sql
      hashing_algorithm: xxh3
```

### Disable Caching Entirely

```yaml
runtime:
  caching:
    sql_results:
      enabled: false
    search_results:
      enabled: false
    embeddings:
      enabled: false
```

## Troubleshooting

| Issue                                                | Solution                                                                                                                                                  |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Always getting `MISS`                                | Check `item_ttl` is long enough; verify `cache_key_type` (`plan` matches equivalent queries, `sql` requires exact strings); a refresh or DML write on a queried table evicts entries (`reason="invalidated"`) unless `stale_while_revalidate_ttl` is set (v2.3.0+) |
| Cache filling up quickly                             | Increase `max_size`, enable `zstd` encoding, or reduce `item_ttl`. **Changed in v2.3.0**: `max_size` counts more of each entry's retained memory          |
| Stale data being served                              | With `stale_while_revalidate_ttl` set, entries are served `STALE` for that window after `item_ttl` expires or (v2.3.0+) after a refresh or DML write — reduce `item_ttl` / the SWR TTL, or send `cache-control: no-cache` |
| Dynamic functions (`NOW()`) returning cached results | Switch to `cache_key_type: plan` or use `cache-control: no-cache`                                                                                         |
| SWR conflict error                                   | Don't set both `runtime.caching.sql_results.stale_while_revalidate_ttl` and `acceleration.params.caching_stale_while_revalidate_ttl` for the same dataset |

## Documentation

- [Caching](https://spiceai.org/docs/features/caching)
- [Runtime Caching Reference](https://spiceai.org/docs/reference/spicepod/runtime#runtimecaching)
- [Caching Refresh Mode](https://spiceai.org/docs/features/data-acceleration/refresh-modes/caching)
