# Failure lab

Deliberately broken fixtures. Each one shows the server failing *safely* — it refuses bad
input, keeps serving the last good snapshot, and never leaks whether a forbidden thing exists.
Point the container (or `offloader validate`) at these to see exactly what each produces.

| Fixture | Injected defect | Caught by | Expected result |
| --- | --- | --- | --- |
| `bad-manifest/manifest.json` | empty `snapshot_id`, duplicate `tenant_id` column, unsupported type `TIMESTAMP_WITH_QUUX`, missing `producer` | manifest validation | rejected with a stable, field-pathed error; snapshot not loaded |
| `stale-dataset/manifest.json` | valid, but `watermark`/`created_at` ~1 month old (> 120-min freshness) | freshness check | flagged stale; still served with honest freshness metadata, or refused per policy |
| `unsupported-schema-change/manifest.json` | valid, but `api_calls` narrowed `BIGINT`→`INTEGER` (type narrowing is breaking) vs the dataset contract under `additive_only` | compatibility check on refresh | refresh rejected; **previous good snapshot preserved** |
| `missing-file/manifest.json` | valid, but `files[0].path` points at a file that does not exist | validation / materialization | rejected before materialization; snapshot not swapped in |
| `bad-param/request.json` | `product_area=billing` — not in the endpoint's enum | endpoint compiler | `422 invalid_param`; no query runs; existence of other values not revealed |
| `forbidden-tenant/request.json` | globex key passes `tenant_id=tenant_acme` to read another tenant | tenant enforcement | `422 invalid_param` — `tenant_id` is not a declared param, so it's rejected before the query; the key-bound tenant filter can't be overridden. Endpoint-scope variant: `404 not_found` (same as unknown — no existence leak) |

## About these fixtures

- The manifest fixtures that reference real data (`stale`, `unsupported-schema-change`)
  point back at `../../data/customer_usage/customer_usage.csv` on purpose — the defect is the
  metadata, not a missing file (that is `missing-file/`).
- Each request fixture documents the exact call and the invariant that must hold at the HTTP
  boundary.
- Stable errors never distinguish "does not exist" from "not allowed" — see the
  [security model](../../../docs/security-model.md).
