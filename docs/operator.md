# Operator guide

Everything an operator needs to run Offloader in production, with real commands and
diagnostics fields. It links to the deep docs rather than repeating them.

## Deploy

The container reads env vars plus config; nothing is baked into the image. Two
variables are required — `OFFLOADER_CONFIG` and `OFFLOADER_SECRET_KEY_BASE` —
and two more are worth setting from day one: `OFFLOADER_ADMIN_TOKEN` (gates
`/diagnostics`) and `OFFLOADER_LOG_LEVEL`. Ready-to-adapt examples for
`docker run`, Compose, Kubernetes, and Prometheus live in
[`../deploy/`](../deploy/README.md).

`OFFLOADER_CONFIG` points at either a **mounted directory** (a path to
`offloader.yml`) or a **`gs://…` bucket prefix**, fetched at boot so the
container is fully stateless. Set `OFFLOADER_CONFIG_SYNC_INTERVAL=<seconds>` and
Offloader re-checks the bucket on that interval and **hot-reloads changes with
no restart** — even a dataset schema change cuts over with zero downtime, and a
bad revision is ignored (the running config keeps serving). Full details:
[config guide](developer-experience.md#config-from-object-storage-optional).

The container listens on two ports: **API** (product traffic, API-key auth) and
**ADMIN** (health, metrics, diagnostics, docs). Keep the admin port private —
see "Port exposure" below.

## Upgrade check and rollback

Always deploy the **published, signed image**, pinned to a version tag — never
`:latest`. Before an instance takes traffic, verify it: both ports up, health
green, diagnostics and metrics responding, and one manifest→HTTP smoke call. A
broken image or config fails here, not in front of a customer.

Upgrades are uneventful by design: there is no schema migration, and the cache
rematerializes from the manifest on boot. Rolling back an image is just
redeploying the previous tag (`kubectl rollout undo`, or `docker compose up`
with the old tag) — health returns immediately.

Snapshots protect themselves: a bad one never swaps in, because validation and
the compatibility gate reject it. To revert a *good-but-wrong* snapshot, roll
the dataset back to its previous good one (see
[runbooks](operations/runbooks.md) → "Rollback to previous snapshot").

## Cache quarantine and rebuild

The materialization cache is a mounted volume. To rebuild: stop the container, remove
the cache volume (one dataset: its materialized files; all: the whole volume), restart
— the server rematerializes from the current manifest. Details:
[runbooks](operations/runbooks.md) → "Cache quarantine and rebuild".

## Sizing

**Memory** scales with what's loaded: the server materializes snapshots into
DuckDB, so RSS follows your active snapshot sizes. The bundled example runs at
~160 MB RSS; size for your largest dataset plus headroom, and measure with the
[benchmark harness](benchmarks.md).

**Disk** is the cache volume, which holds the DuckDB file(s). Size it for your
largest snapshot plus a retained previous snapshot, plus margin —
`offloader_cache_disk_free_bytes` alerts before it fills.

**CPU** buys concurrency. Reads are served from a materialized table across a
pool of DuckDB read connections (`OFFLOADER_POOL_SIZE`, default 16), so requests
run concurrently and throughput scales with the pool size, not a single queue.
When every connection is busy, a request is shed as a `503` rather than queueing
unboundedly — if you see that under load, raise the pool size (and CPU). Watch
p95 (95th-percentile latency) with the [benchmark harness](benchmarks.md).

## Security model

API keys are hashed at rest, revocable, scoped to endpoints, and tenant-bound;
the compiler inserts the tenant filter and it cannot be overridden. Mint keys
with `offloader keys create` — the token is shown once, and only its hash is
stored. An adversarial security test suite exercises these invariants on every
build (cross-tenant reads, key-scope escapes, injection, and more). The full
model is in [`security-model.md`](security-model.md).

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

These are two independent axes. For **throughput**, scale a single instance:
reads run on a DuckDB connection pool sized with `OFFLOADER_POOL_SIZE`, and you
bound memory with `OFFLOADER_DUCKDB_THREADS` / `OFFLOADER_DUCKDB_MEMORY_LIMIT`.
A saturated pool sheds excess load as a retryable `503`.

For **availability**, scale out: an instance is **stateless** — it materializes
each snapshot into its own local cache from the bucket and serves reads with no
shared state or coordination. Run N behind your load balancer; each loads config
and snapshots independently, and any instance can serve any request. Keep each
instance's admin port private.

## Support

Support is a **response-time commitment**, not an uptime SLA — you run the container, so
availability is yours, and you email a person, not a queue. The
[ownership matrix](operations/ownership.md) spells out what Offloader covers versus what stays
with your environment (upstream pipelines, IAM, network, resources, config content).

## Troubleshooting

Symptom → signals → owner → action for every incident class:
[`operations/runbooks.md`](operations/runbooks.md). The first step is always
classification (Offloader vs customer environment vs upstream data) from `/diagnostics`.
