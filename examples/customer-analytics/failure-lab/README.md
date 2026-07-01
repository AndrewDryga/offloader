# Failure lab

Deliberately broken fixtures. Each one proves the gateway fails *safely* — it
refuses bad input, keeps serving the last good snapshot, and never leaks whether a
forbidden thing exists. These drive the manifest validator (G03), the endpoint
runtime (G05), auth/tenant enforcement (G06), refresh/rollback (G08), the
adversarial suite (S01), and the "one failure example" in the quickstart (D01).

| Fixture | Injected defect | Caught by | Expected result |
| --- | --- | --- | --- |
| `bad-manifest/manifest.json` | empty `snapshot_id`, duplicate `tenant_id` column, unsupported type `TIMESTAMP_WITH_QUUX`, missing `producer` | manifest validator (G03) | rejected with a stable, field-pathed error; snapshot not loaded |
| `stale-dataset/manifest.json` | valid, but `watermark`/`created_at` ~1 month old (> 120-min freshness) | freshness check (G08/G09) | flagged stale; still served with honest freshness metadata, or refused per policy |
| `unsupported-schema-change/manifest.json` | valid, but `api_calls` narrowed `BIGINT`→`INTEGER` (type narrowing is breaking) vs the dataset contract under `additive_only` | compatibility check on refresh (G08) | refresh rejected; **previous good snapshot preserved** |
| `missing-file/manifest.json` | valid, but `files[0].path` points at a file that does not exist | validator / materializer (G03/G04) | rejected before materialization; snapshot not swapped in |
| `bad-param/request.json` | `product_area=billing` — not in the endpoint's enum | endpoint compiler (G05) | `422 invalid_param`; no query runs; existence of other values not revealed |
| `forbidden-tenant/request.json` | globex key passes `tenant_id=tenant_acme` to read another tenant | compiler + tenant enforcement (G05/G06) | `422 invalid_param` — `tenant_id` is not a declared param, so it's rejected before the query; the key-bound tenant filter can't be overridden. Endpoint-scope variant: `404 not_found` (same as unknown — no existence leak) |

## Notes

- The manifest fixtures that reference real data (`stale`, `unsupported-schema-change`)
  point back at `../../data/customer_usage/customer_usage.csv` on purpose — the
  defect is the metadata, not a missing file (that is `missing-file/`).
- Request fixtures document the exact call and the *invariant* that must hold, so
  S01 can assert them at the HTTP boundary and D01 can show them in the quickstart.
- Stable errors must not distinguish "does not exist" from "not allowed" — see
  `docs/security-model.md`.
