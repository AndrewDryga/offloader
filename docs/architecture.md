# Offloader Architecture

## Design

Offloader is a small, boring, customer-run data plane:

- Phoenix/Elixir self-hostable container for REST contracts, consumer API keys,
  tenancy, refresh supervision, and operational endpoints.
- DuckDB as the default embedded execution engine.
- Local on-disk materialization as the default hot path.
- Direct object-store Parquet scanning as an explicit mode for cold, low-QPS, or
  oversized endpoints after benchmarking.
- Environment variables plus config from a mounted directory OR a `gs://` bucket (fetched at
  boot, with optional zero-downtime hot-reload) as the deployment interface.
- Separate API and admin/metrics ports. Customers own network exposure, reverse
  proxies, IAM, SSO, RBAC, and service discovery outside the container.
- Optional helper tooling for validation, diagnostics, endpoint tests, and
  support bundles.

Offloader is a single-node embedded engine, not a distributed query engine and not a hosted
control plane — there's no ClickHouse/DataFusion cluster, no SaaS control plane, and no built-in
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

Set `serving_mode` per endpoint (`local_table` is the default if omitted):

- **Default to `local_table`.** It materializes the snapshot into a DuckDB table
  once per refresh, so every query is a fast in-memory read. Use it for hot,
  high-QPS, tight-p95 product endpoints — the common case.
- **Use `remote_scan` only with benchmark evidence.** It reads the snapshot's
  source files directly on every request (no materialization), trading per-query
  latency for zero materialization cost and memory. It fits cold, low-QPS, or
  oversized endpoints. Don't put a p95-sensitive endpoint on `remote_scan` without measuring it
  first with the [benchmark harness](benchmarks.md).
- Both modes run the identical compiled plan and return identical results — the
  only difference is where DuckDB reads from.

`cache.policy: snapshot` adds a response cache on top of either mode. The cache
key is `(endpoint, version, tenant, request params, snapshot_id)`, so it is safe
by construction: it never crosses tenants, and a new snapshot invalidates every
entry (invalidation is snapshot-based, never time-based). Turn it on for endpoints
whose repeated same-param reads are worth caching; leave it `none` otherwise.

## Snapshot manifest contract

A manifest is a small JSON file that points Offloader at one snapshot's files and declares its
shape. You rarely hand-write one — your snapshot pipeline (or the Databricks source) generates
it, and `offloader manifest validate` checks it. Required fields:

- `dataset_id`
- `snapshot_id`
- `created_at`
- `watermark`
- `schema`
- `files`
- `partition_columns`
- `sort_columns`
- `row_count`
- `size_bytes`
- `producer`
- `upstream_run_id`
- `schema_version`
- `data_quality_status`
- `compatibility_policy`

Rules:

- Upstream pipeline publishes the manifest only after files are complete.
- Server never serves a partial refresh.
- Failed validation preserves the previous good snapshot.
- Additive columns are allowed when endpoint contracts tolerate them.
- Type narrowing, dropped required columns, and renamed columns are breaking.
- Governance is not inherited automatically after copying into DuckDB; Offloader serves only
  approved serving datasets with pre-authorized columns and simple tenant filters.

## Security invariant

> A consumer key can only access endpoints explicitly granted to that key, for
> tenants bound to that key, selecting only allowed columns, with tenant filters
> inserted by the compiler and impossible to override.

## Guarantees

- The manifest validator rejects missing files, schema mismatch, duplicate columns,
  unsupported types, and bad snapshot IDs.
- A failed refresh preserves the previous good snapshot — a bad revision never swaps in.
- Every response includes its `snapshot_id` and freshness metadata.
- The API port requires an API key; admin-port exposure is yours to control.
- The tenant filter is inserted by the compiler and cannot be overridden by a caller.
