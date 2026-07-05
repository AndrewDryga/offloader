# Offloader Architecture

## Design

Offloader is a small, boring, customer-run data plane. The whole product is one
self-hostable Phoenix/Elixir container: it holds your REST endpoint contracts,
your consumer API keys and tenant enforcement, the refresh supervision, and the
operational endpoints. Queries run on DuckDB, embedded in the same container —
there is no separate query cluster to deploy or operate.

The hot path is local by default. Each refresh materializes the active snapshot
onto local disk, so requests read from a fast local table instead of the object
store. Scanning Parquet directly from the object store exists too, but as an
explicit per-endpoint mode for cold, low-QPS, or oversized data — something you
opt into after benchmarking, never a silent fallback.

Deployment is environment variables plus config from a mounted directory or a
`gs://` bucket, fetched at boot with optional zero-downtime hot-reload. The
container listens on two ports — API for product traffic, admin for metrics and
diagnostics — and everything around them stays yours: network exposure, reverse
proxies, IAM, SSO, RBAC, and service discovery all live outside the container.
Optional helper tooling covers config validation, diagnostics, endpoint tests,
and support bundles.

Just as deliberate is what Offloader is not: it is a single-node embedded
engine, not a distributed query engine, and not a hosted control plane. There is
no ClickHouse/DataFusion cluster, no SaaS control plane, and no built-in
RBAC/SSO.

## Runtime pipeline

```text
Endpoint config + manifest
        |
        v
Env vars + mounted config + manifest validators
        |
        v
Snapshot resolver -> source adapter -> materializer
        |
        v
DuckDB local table / direct scan / response cache
        |
        v
Endpoint compiler -> REST JSON response
```

## Runtime ports

| Port | Purpose | Access control |
| --- | --- | --- |
| API port | Product endpoint traffic. | Endpoint API keys, endpoint allowlists, tenant filters, and column allowlists. |
| Admin port | `/live`, `/ready`, `/status`, `/metrics`, `/diagnostics`, generated docs/schema, support-bundle export. | Not a user-management surface. You restrict access with your own network, proxy, IAM, SSO, or firewall. |

Offloader has no built-in RBAC, SSO, org/team management, or hosted fleet management. If you want
enterprise access controls, run the admin port behind the controls you already use.

## Serving modes

| Mode | Use for | Notes |
| --- | --- | --- |
| `local_table` | High-QPS, tight p95/p99, repeated product APIs. | Default production hot path. |
| `remote_scan` | Cold endpoints, huge datasets, selective filters, evaluation/debug. | First-class mode, not default. |
| `response_cache` | Same params repeated against same snapshot. | Add when endpoint semantics are stable. |

### Choosing a serving mode

Set `serving_mode` per endpoint; `local_table` is the default if omitted, and
the right choice for the common case — hot, high-QPS, tight-p95 product
endpoints. It materializes the snapshot into a DuckDB table once per refresh, so
every query after that is a fast in-memory read.

`remote_scan` reads the snapshot's source files directly on every request.
Nothing is materialized, which saves the load time and the memory — but every
query now pays object-store latency. That trade fits cold, low-QPS, or oversized
endpoints. Don't put a p95-sensitive endpoint on `remote_scan` without measuring
it first with the [benchmark harness](benchmarks.md).

Whichever mode an endpoint uses, it runs the identical compiled plan and returns
identical results — the only difference is where DuckDB reads from.

`cache.policy: snapshot` adds a response cache on top of either mode. The cache
key is `(endpoint, version, tenant, request params, snapshot_id)`, so it is safe
by construction: it never crosses tenants, and a new snapshot invalidates every
entry (invalidation is snapshot-based, never time-based). Turn it on for endpoints
whose repeated same-param reads are worth caching; leave it `none` otherwise.

### Getting the most from `remote_scan`

`remote_scan` pays object-store latency per request, so its performance depends on how
little data DuckDB has to fetch and how many reads run at once:

- **Sort (and bloom-filter) the Parquet on the columns your endpoints filter — producer
  side.** DuckDB pushes the endpoint's `WHERE` into `read_parquet` and skips any row group
  whose min/max (or bloom filter) rules out a match — but only if the file is *laid out* for
  it. A snapshot sorted by `tenant_id, <filter columns>` lets a selective query read a
  handful of row groups instead of the whole file; an unsorted export makes DuckDB scan
  everything. This is the single biggest lever for `remote_scan`, and it lives in **your
  snapshot pipeline** (e.g. `ORDER BY` / `sortWithinPartitions` before the Databricks/Spark
  write), not in Offloader — Offloader reads a snapshot's files read-only and can't reorder
  them. (The materialized `local_table` path sorts on refresh for you; the remote path can't.)
- **Object-store metadata is cached automatically.** Offloader enables DuckDB's HTTP-metadata
  and object caches, so a file's Parquet footer is fetched once, not on every request — safe
  because snapshots are immutable (a new snapshot is new file URLs). No configuration needed.
- **`remote_scan` concurrency is capped so it can't starve `local_table`.** A burst of
  cache-miss reads on a huge remote dataset can each hold a connection for the whole slow
  fetch; the engine limits how many run at once (`OFFLOADER_REMOTE_SCAN_CONCURRENCY`, default
  `min(pool_size, 16)`), reserving the rest of the read pool for fast local queries. Size the
  pool up for local throughput without letting remote reads follow it up. See
  [config-reference](config-reference.md).

## Snapshot manifest contract

A manifest is a small JSON file that points Offloader at one snapshot's files and declares its
shape. You rarely hand-write one — your snapshot pipeline (or the Databricks source) generates
it, and `offloader manifest validate` checks it. Every manifest carries `dataset_id`,
`snapshot_id`, `created_at`, `watermark`, `schema`, `files`, `partition_columns`,
`sort_columns`, `row_count`, `size_bytes`, `producer`, `upstream_run_id`, `schema_version`,
`data_quality_status`, and `compatibility_policy` — all required.

The contract behind it is what makes refreshes safe. The producer publishes the
manifest last, only after every file it references is complete, so a manifest on
the bucket always describes a finished snapshot — the server never serves a
partial refresh. And if a new snapshot fails validation, nothing changes: the
previous good snapshot keeps serving.

Schema changes follow the same conservative rule. Adding a column is fine when
the endpoint contracts tolerate it; narrowing a type, dropping a required
column, or renaming one is breaking, and the compatibility gate rejects it.

One thing the manifest does *not* carry: your warehouse's governance. Copying
data into DuckDB doesn't inherit upstream access policies, which is why
Offloader serves only approved serving datasets, with pre-authorized columns and
simple tenant filters.

## Security invariant

> A consumer key can only access endpoints explicitly granted to that key, for
> tenants bound to that key, selecting only allowed columns, with tenant filters
> inserted by the compiler and impossible to override.

## Guarantees

Before anything is served, the manifest validator rejects missing files, schema
mismatches, duplicate columns, unsupported types, and bad snapshot IDs. A
refresh that fails never swaps in — the previous good snapshot keeps serving, so
a bad revision can't take an endpoint down. Every response includes its
`snapshot_id` and freshness metadata, so a caller always knows exactly which
data it got.

On the auth side: the API port requires an API key, and the tenant filter is
inserted by the compiler — a caller cannot override it. The admin port is
separate, and how it's exposed is yours to control.
