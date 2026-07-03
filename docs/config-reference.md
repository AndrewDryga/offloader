# Config reference

Every field of an Offloader project, with the exact allowed values. New to the pieces
(dataset, endpoint, snapshot, project)? Read [Concepts](concepts.md) first. For a complete
working project to copy, see `examples/customer-analytics/`.

> **Don't hand-write it.** `offloader init` scaffolds a valid, fully-commented starter
> project, and `offloader scaffold-dataset --from <manifest.json|data.csv>` drafts a
> dataset's schema for you. See [Start a new project](developer-experience.md#start-a-new-project-scaffold).

A project is four kinds of file:

```text
offloader.yml       project file — which dirs to load, auth mode, keys path
datasets/*.yml      one per dataset — the table + the columns you expect
endpoints/*.yml     one per endpoint — the REST contract over a dataset
keys/keys.yml       API keys (hashes only) — omit for a public (auth: none) API
```

Run `offloader validate --config <path>/offloader.yml` to check the whole tree; it reports
every problem at once.

---

## `offloader.yml`

The top-level project file `OFFLOADER_CONFIG` points at.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `version` | integer | yes | Config schema version. Currently `1`. |
| `datasets_dir` | string | no | Directory of dataset files, relative to this file. Default `datasets`. |
| `endpoints_dir` | string | no | Directory of endpoint files. Default `endpoints`. |
| `keys` | string | no | Path to the keys file, relative to this file. Omit for a public API. |
| `auth` | `required` \| `none` | no | Default `required` (every request needs an API key). `none` serves publicly — **accepted only when no endpoint is tenant-scoped**. |
| `object_store_mode` | string | no | Informational tag for the snapshot source (`local`, `gcs`, …). Credentials come from env vars, never this file. |

```yaml
version: 1
datasets_dir: datasets
endpoints_dir: endpoints
keys: keys/keys.yml
```

---

## `datasets/*.yml`

A dataset is a named table Offloader serves, plus the schema it expects. One file per dataset.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `id` | string | yes | Lowercase identifier (`[a-z][a-z0-9_]*`). Used in endpoints and URLs. |
| `description` | string | no | Free text. |
| `schema` | list of `{name, type}` | yes | The columns the gateway expects. See types below. |
| `tenant_column` | string | no | The column that identifies a tenant. If set, every endpoint on this dataset is tenant-scoped and the value is bound from the caller's key — never a request param. |
| `manifest` | string | one of `manifest`/`source` | Path (relative to the project) to a snapshot manifest — for local/static snapshots. |
| `source` | object | one of `manifest`/`source` | A remote source that discovers the latest snapshot itself (see below). |

**Column types** (`schema[].type`): `DATE`, `TIMESTAMP`, `VARCHAR`, `INTEGER`, `BIGINT`,
`DOUBLE`, `BOOLEAN`, `JSON`. Use **`JSON`** for a nested column (`STRUCT`/`MAP`/`LIST` in the
snapshot); the endpoint serves it as a nested JSON object.

**`source:` (a self-updating remote snapshot):**

| Field | Type | Notes |
| --- | --- | --- |
| `type` | `databricks` | The commit-protocol resolver: finds the latest `_committed_<tid>` in the bucket. |
| `bucket` | string | Object-storage bucket. |
| `prefix` | string | Path prefix within the bucket (ends with `/`). |
| `interval_seconds` | integer | How often to re-check for a newer snapshot. |

```yaml
id: customer_usage
description: Daily product-usage rollup, one row per (usage_date, tenant_id, account_id).
tenant_column: tenant_id
manifest: data/customer_usage/manifest.json      # or use `source:` for a remote bucket
schema:
  - { name: usage_date,  type: DATE }
  - { name: tenant_id,   type: VARCHAR }
  - { name: account_id,  type: VARCHAR }
  - { name: api_calls,   type: BIGINT }
  - { name: storage_gb,  type: DOUBLE }
  - { name: stats,       type: JSON }            # nested column → served as a JSON object
```

---

## `endpoints/*.yml`

An endpoint is the REST contract over a dataset — its URL, params, query, and limits. There is
no SQL here; the compiler turns this into a safe, parameterized query. One file per endpoint.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `name` | string | yes | The URL name: `GET /v1/endpoints/<name>`. |
| `version` | integer | yes | Contract version. Bump it when you change the response shape (invalidates the response cache). |
| `dataset` | string | yes | The `id` of the dataset it reads. |
| `owner` | string | no | Team/contact. |
| `description` | string | no | Free text; shows in the generated docs. |
| `serving_mode` | `local_table` \| `remote_scan` | no | Default `local_table` (materialized, fast). `remote_scan` reads the snapshot files per request — for cold/huge/low-QPS endpoints. |
| `tenant` | `{column}` | no | Binds the tenant filter to this column (must match the dataset's `tenant_column`). Inserted server-side; a caller cannot override it. |
| `freshness` | `{max_staleness_minutes}` | no | Marks a response `stale: true` past this age. Informational — the response still serves. |
| `params` | list | no | The query params a caller may send (below). |
| `combinations` | list of lists | no | Exact allowed sets of client-sent params (below). |
| `query` | object | yes | `select` / `filters` / `group_by` / `order_by` (below). |
| `columns` | list of strings | yes | Allowlist of columns a response may contain. Nothing outside this can be returned. |
| `pagination` | `{default_limit, max_limit}` | no | Caps `?limit=`. |
| `cache` | `{policy}` | no | `none` (default) or `snapshot` (cache responses; a new snapshot invalidates them). |

### `params[]`

| Field | Type | Notes |
| --- | --- | --- |
| `name` | string | The query-param name. |
| `type` | `string` \| `integer` \| `date` \| `enum` | Param types. |
| `required` | boolean | Default `false`. |
| `default` | value | Applied when the caller omits it. Must satisfy `type`. |
| `enum` | list | For `type: enum` — the allowed values. |
| `max` | integer | For `type: integer` — the upper bound. |
| `aliases` | map `value → value` | Rewrites a client value to a stored one before filtering (e.g. `"25": "1-25"`). |

### `query`

- `select`: list of `{as, column}` or `{as, column, agg}`. **`agg`** ∈ `sum`, `avg`, `min`, `max`, `count`.
- `filters`: list of `{column, op, param}`. **`op`** ∈ `eq`, `gte`, `lte`. The filter is applied only when the caller sends (or defaults) that param.
- `group_by`: list of column names (required when any `select` uses an `agg`).
- `order_by`: list of `{column, dir}`. **`dir`** ∈ `asc`, `desc`.

### `combinations`

Optional. Each entry is an exact set of the **client-sent** param names allowed together
(checked before defaults are applied). Omit `combinations` to allow any subset. Reserved params
(`limit`, `offset`, `columns`) never count toward a combination.

```yaml
name: customer_usage_summary
version: 1
dataset: customer_usage
serving_mode: local_table
freshness: { max_staleness_minutes: 120 }
tenant: { column: tenant_id }
params:
  - { name: account_id, type: string, required: false }
  - { name: from, type: date, required: true }
  - { name: to,   type: date, required: true }
combinations:
  - [from, to]
  - [account_id, from, to]
query:
  group_by: [account_id]
  select:
    - { as: account_id,     column: account_id }
    - { as: api_calls_total, column: api_calls, agg: sum }
    - { as: storage_gb_avg,  column: storage_gb, agg: avg }
  filters:
    - { column: account_id, op: eq,  param: account_id }
    - { column: usage_date, op: gte, param: from }
    - { column: usage_date, op: lte, param: to }
  order_by:
    - { column: api_calls_total, dir: desc }
columns: [account_id, api_calls_total, storage_gb_avg]
pagination: { default_limit: 50, max_limit: 100 }
cache: { policy: snapshot }
```

Every caller also gets, for free: `?limit=` / `?offset=` (bounded by `pagination`) and a
`?columns=a,b` subset of the allowlist. See the [Consumer API](api.md) for the request/response
contract.

---

## `keys/keys.yml`

API keys, as a top-level `keys:` list. Tokens are never stored — only the SHA-256 hash. Mint one
with `offloader keys create` (it prints the token once and its hash). Omit this file for a public
(`auth: none`) API.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | Label for the key (appears in diagnostics, never the token). |
| `hash` | string | 64-char lowercase SHA-256 hex of the bearer token. |
| `tenant` | string | The single tenant this key is bound to (`null` for a non-tenant key). |
| `endpoints` | list of strings | The endpoint names this key may call. |
| `status` | `active` \| `revoked` | `revoked` is always denied. |

```yaml
keys:
  - id: acme_prod
    hash: "745ce437a64ab1f020c303be50aa3785e742b72e61533d692f7aa024ff16b121"
    tenant: tenant_acme
    endpoints: [customer_usage_summary, customer_usage_daily]
    status: active
```
