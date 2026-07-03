# Offloader Architecture

## Decision

Use a small, boring, customer-run data plane:

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

Do not rewrite to a distributed query engine for V1. Keep ClickHouse, DataFusion,
hosted cloud, RBAC/SSO, and a SaaS control plane out of the product.

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

| Port | Purpose | Product stance |
| --- | --- | --- |
| API port | Customer-facing endpoint traffic. | Uses endpoint API keys, endpoint allowlists, tenant filters, and column allowlists. |
| Admin port | `/live`, `/ready`, `/status`, `/metrics`, `/diagnostics`, generated docs/schema, support-bundle export. | Not a user-management surface. Customers restrict access with their own network, proxy, IAM, SSO, or firewall controls. |

Do not add RBAC, SSO, organization management, teams, invitations, or hosted
fleet management to V1. If a customer wants enterprise access controls, they run
the admin port behind the controls they already use.

## Serving modes

| Mode | Use for | V1 posture |
| --- | --- | --- |
| `local_table` | High-QPS, tight p95/p99, repeated product APIs. | Default production hot path. |
| `remote_scan` | Cold endpoints, huge datasets, selective filters, proof/debug. | First-class mode, not default. |
| `response_cache` | Same params repeated against same snapshot. | Add when endpoint semantics are stable. |

### Choosing a serving mode

Set `serving_mode` per endpoint (`local_table` is the default if omitted):

- **Default to `local_table`.** It materializes the snapshot into a DuckDB table
  once per refresh, so every query is a fast in-memory read. Use it for hot,
  high-QPS, tight-p95 product endpoints — the common case.
- **Use `remote_scan` only with benchmark evidence.** It reads the snapshot's
  source files directly on every request (no materialization), trading per-query
  latency for zero materialization cost and memory. It fits cold, low-QPS, or
  oversized endpoints. Do not put a p95-sensitive endpoint on `remote_scan`
  without measuring it (`dev/scripts/bench-modes.exs`).
- Both modes run the identical compiled plan and return identical results — the
  only difference is where DuckDB reads from.

`cache.policy: snapshot` adds a response cache on top of either mode. The cache
key is `(endpoint, version, tenant, request params, snapshot_id)`, so it is safe
by construction: it never crosses tenants, and a new snapshot invalidates every
entry (invalidation is snapshot-based, never time-based). Turn it on for endpoints
whose repeated same-param reads are worth caching; leave it `none` otherwise.

## Snapshot manifest contract

A manifest is a small JSON file that points Offloader at one snapshot's files and declares its
shape. You rarely hand-write one — `offloader import-schema` and the Databricks source generate
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
- Gateway never serves a partial refresh.
- Failed validation preserves the previous good snapshot.
- Additive columns are allowed when endpoint contracts tolerate them.
- Type narrowing, dropped required columns, and renamed columns are breaking.
- Governance is not inherited automatically after copying into DuckDB; V1 serves
  only approved serving datasets with pre-authorized columns and simple tenant
  filters.

## Security invariant

> A consumer key can only access endpoints explicitly granted to that key, for
> tenants bound to that key, selecting only allowed columns, with tenant filters
> inserted by the compiler and impossible to override.

## Pre-pilot technical gates

- One representative dataset family, 3 endpoints, generic public routes, and generated
  docs/schema on the admin port.
- Manifest validator rejects missing files, schema mismatch, duplicate columns,
  unsupported types, and bad snapshot IDs.
- Failed refresh preserves previous good snapshot.
- Responses include `snapshot_id` and freshness metadata.
- API key required on the API port; admin port exposure is customer-controlled.
- Tenant filter cannot be overridden by caller.
- Cold load, warm restart, memory, disk, p95, and p99 measured at concurrency 1,
  10, and 50.
- Standalone image starts from empty cache and warm cache.
- Integration test covers manifest to DuckDB materialization to HTTP response.
