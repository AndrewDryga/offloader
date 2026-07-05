# Consumer API

What a client — your product code or front-end — sees when it calls an Offloader endpoint.
This is the stable contract; the config that produces it is in the [config reference](config-reference.md).

## The request

```
GET /v1/endpoints/<name>?<params>
Authorization: Bearer <token>          # omit for a public (auth: none) API
```

- `<name>` is the endpoint's `name`. `/v1/` is the API version (not the endpoint's `version`).
- **Params** are whatever the endpoint declares, plus three every endpoint gets for free:

| Param | Meaning |
| --- | --- |
| `limit` | Max rows. Bounded by the endpoint's `pagination.max_limit`. |
| `offset` | Rows to skip (simple paging). |
| `columns` | Comma-separated subset of the endpoint's allowlist, e.g. `?columns=account_id,api_calls_total`. |

A value with a literal `+` is sent URL-encoded (`%2B`); a space decodes to `+` on the way in.

## The response

Always the same envelope: `data` (the rows) + `meta` (what you're reading).

```json
{
  "data": [
    { "account_id": "acct_zephyr", "active_users_total": 244, "api_calls_total": 56839, "storage_gb_avg": 34.300000000000004 }
  ],
  "meta": {
    "request_id":   "GL6f4CKamol9",
    "endpoint":     "customer_usage_summary",
    "version":      1,
    "snapshot_id":  "2026-06-01T00:00:00Z_r0007",
    "generated_at": "2026-07-01T18:21:10Z",
    "row_count":    1,
    "serving_mode": "local_table",
    "cache":        "hit",
    "freshness": {
      "watermark":            "2026-06-01T00:00:00Z",
      "age_seconds":          2658070,
      "max_staleness_minutes": 120,
      "stale":                 true
    }
  }
}
```

| `meta` field | Meaning |
| --- | --- |
| `request_id` | Correlates with server logs; echo it when reporting an issue. |
| `version` | The endpoint's contract version (from its config). Changes when the operator revises the endpoint. |
| `snapshot_id` | Exactly which snapshot answered — stable until a newer one swaps in. Good cache key. |
| `serving_mode` | `local_table` or `remote_scan`. |
| `cache` | `hit` / `miss` (response cache) or `off` (endpoint not cached). |
| `freshness.watermark` | The snapshot's timestamp. |
| `freshness.age_seconds` | How old the data is right now. |
| `freshness.stale` | `true` when older than the endpoint's `max_staleness_minutes`. |

**Reacting to `stale: true`:** the response is still valid data — it's a *hint*, not an error. Show
it, optionally with an "updated N minutes ago" note. It clears when the next snapshot lands.

Nested columns declared `JSON` come back as real nested objects, not strings.

Computed numeric columns (an `avg`, say) are returned as full-precision floating-point — e.g.
`34.300000000000004`, not `34.3` — so compare them with a tolerance rather than for exact
equality. Values you store and pass through keep whatever precision they had.

## Errors

Errors return a stable shape and a terse message — a forbidden endpoint and a non-existent one
look identical on purpose, so probing can't map what exists. Every error body is:

```json
{ "error": { "family": "not_found", "message": "endpoint not found" },
  "meta":  { "request_id": "GL6f4CKamol9" } }
```

`error.family` is the stable machine-readable code (`invalid_param`, `unauthorized`,
`not_found`, `not_ready`, `internal`); `error.message` is safe to log but never echoes a raw
param, secret, or SQL.

| HTTP | When | What the client should do |
| --- | --- | --- |
| `200` | OK | — |
| `401` | Missing / invalid / revoked key | Fix the `Authorization` header. |
| `404` | Unknown endpoint, or the key isn't granted it (indistinguishable) | Check the name and the key's grants. |
| `422` | A param is missing / mistyped / out of range, or an undeclared param was sent | Fix the params. |
| `503` | The snapshot isn't materialized yet (`not_ready`) | Retry with backoff; it clears once ready. |
| `500` | Internal error | Retry; if it persists, capture `request_id` and a support bundle. |

## Discovering endpoints

The generated endpoint catalog and OpenAPI live on the **admin** port (`/docs`, `/openapi.json`,
`/schema`), which operators keep private. Ask your operator for the OpenAPI spec to generate a
typed client, or the `/schema` output for the params and response shape of each endpoint.

## Caching at the edge

Public (`auth: none`) endpoints are safe to cache: the response is immutable for a given
`snapshot_id`, and a new snapshot changes it. Front a public deployment with your CDN, and use the
response headers (`ETag`, `Cache-Control`) for cheap revalidation. See
[Serving public data](public-serving.md).
