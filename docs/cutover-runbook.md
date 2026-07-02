# Cutover runbook — upstream_serving_api → Offloader

How to move production read traffic from `upstream_serving_api` to Offloader safely, with a
proven-parity gate and a one-command rollback at every step. Nothing here is
irreversible until the final DNS/route switch, and even that reverts in seconds.

## 0. Prerequisites

- A generated Offloader project from the live serving schema:
  `offloader import-schema --from serving_schema.json --hints <hints>.json
  --out ./project --bucket <bucket>` (see `developer-experience.md`). This also writes
  `project/mapping.json` (upstream query → Offloader endpoint), used by the diff harness.
- Offloader deployed alongside upstream, reading the SAME GCS bucket
  (`OFFLOADER_GCS_AUTH=bearer` or HMAC), warm (all datasets `ready` — check
  `/ready` on the admin port).
- Scrape `/metrics` into the same Prometheus as upstream (see the request + pool series
  in `benchmarks.md`).

## 1. Parity gate (offline, before any traffic)

Replay a representative request set against BOTH systems and require zero mismatches:

```sh
# requests.jsonl: one {"game","query","params"} per line — sample from prod access logs
offloader shadow-diff \
  --requests requests.jsonl \
  --upstream-url https://upstream.internal \
  --offloader-url https://offloader.internal \
  --mapping ./project/mapping.json \
  --report parity.json
```

The harness compares only `data` (the `meta` envelopes differ by design), matches rows
as a multiset (row ORDER is not significant), and rounds floats (`--precision`, default
6 decimals) so representation noise isn't a diff. Exit code is non-zero on ANY
mismatch/error, so it gates a CI job. Investigate every mismatch:

- **missing-in-offloader / extra-in-offloader rows** — usually a filter-combination or
  a param-alias difference; check the endpoint's `combinations`/`aliases`.
- **error** — an unmapped query (a `--skip-broken` casualty from import) or an endpoint
  not ready. Unmapped queries must stay on upstream until converted.

Do not proceed until the representative set is clean (or every remaining diff is
understood and signed off).

## 2. Shadow (mirror) — no user impact

Mirror a copy of live prod traffic to Offloader (via your proxy/load-balancer's
mirror/shadow feature) while ALL real responses still come from upstream. Watch for a
soak period (≥ 24 h across a refresh cycle):

- `offloader_requests_total{status="server_error"}` and `{status="not_ready"}` — must be ~0.
- `offloader_request_duration_ms` p99 — within your SLO.
- `offloader_pool_busy` vs `offloader_pool_connections` — sustained saturation means
  raise `OFFLOADER_POOL_SIZE` (and CPU) before taking real traffic.
- `offloader_snapshot_age_seconds` / `offloader_refresh_ok` — refresh is keeping up.

## 3. Canary — 1% → 10% → 50% → 100%

Shift a percentage of REAL traffic to Offloader at your edge, pausing at each step.
Advance only when, over the step's window, ALL hold:

- error rate (5xx) at parity with upstream or better,
- p99 within SLO,
- the parity harness (run against live-sampled requests) stays clean,
- no unexpected `not_ready` (a dataset fell behind its source).

Roll back a step instantly by returning the weight to upstream — Offloader holds no
write state, so there is nothing to reconcile.

## 4. Cutover + decommission

At 100% and stable for a full soak, make Offloader the default route and leave upstream
running (cheap insurance) for one more cycle before decommissioning. Keep the generated
project + `mapping.json` in version control so the schema and the routing stay in sync.

## Rollback (any step)

Return the edge weight/route to upstream. Because Offloader is read-only over immutable
snapshots, rollback is a routing change with no data migration. If Offloader itself is
unhealthy, `/live` (liveness) stays up while `/ready` reports the problem — so an
orchestrator restarts it rather than routing to a cold instance.
