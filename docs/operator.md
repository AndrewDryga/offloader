# Operator guide

Everything an operator needs to run Offloader in production, with real commands and
diagnostics fields. It links to the deep docs rather than repeating them.

## Deploy

- Examples for `docker run`, Compose, Kubernetes, and Prometheus:
  [`../deploy/`](../deploy/README.md).
- The container reads env vars + config; nothing is baked into the image. Required:
  `OFFLOADER_CONFIG`, `OFFLOADER_SECRET_KEY_BASE`. Recommended: `OFFLOADER_ADMIN_TOKEN`
  (gates `/diagnostics`), `OFFLOADER_LOG_LEVEL`.
- **Config source:** `OFFLOADER_CONFIG` is either a **mounted directory** (a path to
  `offloader.yml`) or a **`gs://…` bucket prefix**, fetched at boot so the container is fully
  stateless. Set `OFFLOADER_CONFIG_SYNC_INTERVAL=<seconds>` and Offloader re-checks the bucket
  on that interval and **hot-reloads changes with no restart** — even a dataset schema change
  cuts over with zero downtime, and a bad revision is ignored (the running config keeps serving).
  Full details: [config guide](developer-experience.md#config-from-object-storage-optional).
- Two ports: **API** (product traffic, API-key auth) and **ADMIN** (health, metrics,
  diagnostics, docs). Keep the admin port private — see "Port exposure" below.

## Upgrade check and rollback

- **Before rollout:** `make deploy-check` builds the production image and boots it
  locally, verifying both ports, health, diagnostics/metrics, and a manifest→HTTP smoke.
  A broken image or config fails here, not in front of a customer.
- **Upgrade:** deploy the new pinned image tag (never `:latest`). There is no schema
  migration; the cache rematerializes from the manifest on boot.
- **Roll back the image:** redeploy the previous tag (`kubectl rollout undo` /
  `docker compose up` with the old tag). Health returns immediately.
- **Roll back a snapshot:** a bad snapshot never swaps in (validation + compatibility
  gate it). To revert a *good-but-wrong* snapshot, roll the dataset back to its previous
  good one (see [runbooks](operations/runbooks.md) → "Rollback to previous snapshot").

## Cache quarantine and rebuild

The materialization cache is a mounted volume. To rebuild: stop the container, remove
the cache volume (one dataset: its materialized files; all: the whole volume), restart
— the gateway rematerializes from the current manifest. Details:
[runbooks](operations/runbooks.md) → "Cache quarantine and rebuild".

## Sizing

- **Memory:** the gateway materializes snapshots into DuckDB; RSS scales with active
  snapshot size. The example runs at ~160 MB RSS; size for your largest dataset plus
  headroom. Measure with the [benchmark harness](benchmarks.md).
- **Disk:** the cache volume holds the DuckDB file(s); size it for your largest
  snapshot plus a retained previous snapshot, plus margin. `offloader_cache_disk_free_bytes`
  alerts before it fills.
- **CPU:** reads are served from a materialized table across a pool of DuckDB read
  connections (`OFFLOADER_POOL_SIZE`, default 16); requests run concurrently, so throughput
  scales with the pool size, not a single queue. When every connection is busy a request is
  shed as `503` rather than queueing unboundedly; raise the pool size (and CPU) if you see
  that under load. Watch p95 (95th-percentile latency) with the [benchmark harness](benchmarks.md).

## Security model

- Full model: [`security-model.md`](security-model.md). API keys are hashed at rest,
  revocable, scoped to endpoints, and tenant-bound; the compiler inserts the tenant
  filter and it cannot be overridden. Mint keys with `offloader keys create` (the token
  is shown once; only its hash is stored).
- The adversarial proof of these invariants is the security suite
  (`gateway/test/offloader/security_suite_test.exs`).

## Port exposure

Offloader ships two ports and redaction; **you** own how the admin port is exposed.
Keep it private (loopback, an internal network, a proxy, or your IAM) — it serves
diagnostics/metrics/docs and is not an identity product. The API port is where product
traffic goes, fronted by your ingress + TLS. Tests prove the admin surface is not
reachable on the API port.

## Support bundle handling

When you need help, produce a **redacted** bundle:

```sh
offloader support-bundle --config /etc/offloader/offloader.yml \
  --admin-url http://127.0.0.1:4001 --admin-token "$OFFLOADER_ADMIN_TOKEN" \
  --out offloader-support.tar.gz
```

Every artifact (config + diagnostics) is redacted before it's written — secrets,
tokens, and credentialed URIs are masked; safe one-way key hashes are kept — and a
`manifest.json` lists what's inside with checksums. Review it, then share it only if
you choose to. Offloader makes no outbound telemetry calls.

## Diagnostics

`curl -H "Authorization: Bearer $OFFLOADER_ADMIN_TOKEN" http://127.0.0.1:4001/diagnostics`
returns, per dataset: active/last-good/last-attempted snapshot, refresh error, source
reachability, manifest validity, staleness, plus DuckDB status, disk free, config-sync
status, and build/config versions. `offloader snapshot status --admin-url … --admin-token …`
prints a concise per-dataset summary. Metrics for alerting are on `/metrics`.

Alerts worth setting (all on `/metrics`):

- `offloader_config_sync_ok == 0` — auto-sync (if enabled) stopped applying the bucket config.
- `offloader_snapshot_age_seconds` too high, or `offloader_refresh_ok == 0` — a dataset fell behind its source.
- `offloader_pool_busy` sustained near `offloader_pool_connections` — you're shedding load; raise `OFFLOADER_POOL_SIZE`.
- `offloader_cache_disk_free_bytes` low — the cache volume is filling.

## Scaling & availability

Two independent axes:

- **Throughput (one instance)** — reads run on a DuckDB connection pool; size it with
  `OFFLOADER_POOL_SIZE`, and bound memory with `OFFLOADER_DUCKDB_THREADS` /
  `OFFLOADER_DUCKDB_MEMORY_LIMIT`. A saturated pool sheds excess as a retryable `503`.
- **Availability (many instances)** — an instance is **stateless**: it materializes each
  snapshot into its own local cache from the bucket and serves reads with no shared state or
  coordination. Run N behind your load balancer; each loads config and snapshots
  independently, and any instance can serve any request. Keep each instance's admin port
  private. (The V1 caveat below is the *support commitment* — response targets, not an uptime
  SLA — not the topology.)

## Support tiers and exclusions

V1 sells **response targets**, not an uptime SLA (until HA reference deployments are
proven). The customer-run ownership matrix and the support exclusions (upstream
pipelines, customer IAM/network, disk/CPU, unsupported config changes, data modeling)
are in [`operations/ownership.md`](operations/ownership.md).

## Troubleshooting

Symptom → signals → owner → action for every V1 incident class:
[`operations/runbooks.md`](operations/runbooks.md). The first step is always
classification (Offloader vs customer environment vs upstream data) from `/diagnostics`.
