# Example: customer usage analytics

A tiny, deterministic **B2B SaaS product-usage** dataset with three endpoints and a
failure lab — the worked example the [quickstart](../../docs/quickstart.md), the e2e
smoke test, the security suite, and the benchmark harness all run on. Copy it and edit
it to shape your own project.

## The domain

A SaaS company serves each of *its* customers a view of *their own* usage. Every
row belongs to a tenant (`tenant_id`), and a tenant must never see another
tenant's data — the reason tenant isolation is a P0 invariant here.

## Layout

```text
customer-analytics/
  offloader.yml                     project config (OFFLOADER_CONFIG points here)
  datasets/customer_usage.yml       dataset contract (expected schema, tenant column)
  endpoints/                        three endpoint contracts (the public API surface)
    customer_usage_summary.yml        aggregated totals per account (date range)
    customer_usage_daily.yml          daily rows for one account (time series)
    top_accounts_by_usage.yml         busiest accounts by API calls (ranking)
  keys/keys.yml                     API key fixtures (hashed, tenant-bound, scoped)
  data/customer_usage/
    customer_usage.csv              the snapshot data (36 rows, checked in)
    manifest.json                   the snapshot manifest (the approved contract)
    generate.py                     regenerates the CSV deterministically
    to_parquet.sh                   optional CSV -> Parquet (for realism)
  failure-lab/                      broken fixtures + expected safe failures
```

## The dataset

`customer_usage` — one row per `(usage_date, tenant_id, account_id, product_area)`.

| column | type | notes |
| --- | --- | --- |
| `usage_date` | DATE | 2026-05-30 .. 2026-06-01 |
| `tenant_id` | VARCHAR | the isolation boundary (`tenant_acme`, `tenant_globex`, `tenant_initech`) |
| `account_id` | VARCHAR | sub-account within a tenant |
| `product_area` | VARCHAR | `dashboards`, `api`, `exports` |
| `active_users` | INTEGER | |
| `api_calls` | BIGINT | |
| `storage_gb` | DOUBLE | |
| `plan` | VARCHAR | never exposed by an endpoint (allowlist proof) |

36 rows total. `data/customer_usage/manifest.json` is the approved snapshot and
carries every field the manifest contract requires (`docs/architecture.md`).

## The endpoints

| endpoint | shape | key params | tenant |
| --- | --- | --- | --- |
| `customer_usage_summary` | aggregate totals per account | `from`, `to`, optional `account_id` | bound from key |
| `customer_usage_daily` | daily rows for one account | `account_id`, `from`, `to`, optional `product_area` (enum) | bound from key |
| `top_accounts_by_usage` | top accounts by API calls | `from`, `to`, `limit` (≤ 50) | bound from key |

Each contract is declarative (params, filters, projection, aggregation, ordering,
pagination, cache, freshness). There is no SQL in a contract — Offloader turns it
into a safe parameterized query and inserts the tenant filter after auth.

## The demo keys

Tokens are non-secret and for local use only; only their SHA-256 hash is stored.

| token (Bearer) | tenant | endpoints | status |
| --- | --- | --- | --- |
| `offl_demo_acme_key` | tenant_acme | all three | active |
| `offl_demo_globex_key` | tenant_globex | summary only | active |
| `offl_demo_revoked_key` | tenant_initech | summary only | revoked (always denied) |

Call an endpoint (see the [quickstart](../../docs/quickstart.md) for the full run):

```sh
curl -H "Authorization: Bearer offl_demo_acme_key" \
  "http://localhost:4000/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01"
```

## Regenerating the data

The CSV is deterministic — re-running the generator reproduces the identical file:

```sh
python3 examples/customer-analytics/data/customer_usage/generate.py
```

If you change the row shape, update `manifest.json` (`row_count`, `size_bytes`)
and the dataset/endpoint contracts to match.

## Failure lab

See [`failure-lab/`](failure-lab/README.md) for the broken fixtures (bad manifest,
stale dataset, unsupported schema change, missing file, bad param, forbidden
tenant) and the safe failure each one must produce.
