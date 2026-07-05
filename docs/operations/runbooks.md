# Runbooks

One short runbook per incident class. The first job is **classification** — is
this an Offloader bug, the customer environment, or upstream data? The admin
`/diagnostics` and `/metrics` answer that in under five minutes. Each runbook:
symptom → signals → likely owner → action → escalation.

> Commands assume the admin port is reachable privately and `OFFLOADER_ADMIN_TOKEN`
> is set. `DIAG` below means `curl -H "Authorization: Bearer $TOKEN" $ADMIN/diagnostics`.

## Server does not start

- **Signals:** container exits on boot; `docker logs` shows a config/secret error.
- **Owner:** customer environment (config/secret) or Offloader (crash).
- **Action:** a missing `OFFLOADER_SECRET_KEY_BASE` or unreadable `OFFLOADER_CONFIG`
  is the usual cause — check both. Validate config: `offloader validate --config …`.
- **Escalate:** if config validates and the secret is set but it still crashes.

## Source credentials fail / bucket or network unreachable

- **Signals:** `offloader_source_reachable == 0`; `DIAG` `source_reachable:false`.
- **Owner:** customer environment (IAM/network/object store).
- **Action:** check the container's network + read-only credentials to the source.
  Offloader keeps serving the last good snapshot meanwhile.

## Bad manifest / dataset refresh fails

- **Signals:** `offloader_refresh_ok == 0`; `DIAG` `last_attempted.status` = rejected
  or failed with a `refresh_error`.
- **Owner:** upstream data (rejected = the producer shipped a bad/breaking manifest)
  or Offloader (failed = materialization error).
- **Action:** read `refresh_error`. `rejected` → fix the upstream manifest (it never
  swapped in, so serving is safe). `failed` → check disk/DuckDB below.

## Dataset stale

- **Signals:** `offloader_snapshot_stale == 1`; response `meta.freshness.stale:true`.
- **Owner:** upstream data (the producer stopped publishing fresh manifests).
- **Action:** check the upstream pipeline. Offloader honestly reports staleness and
  keeps serving the last good snapshot.

## DuckDB cache corrupted / DuckDB failure

- **Signals:** `offloader_duckdb_up == 0`; queries error.
- **Owner:** Offloader / environment (disk).
- **Action:** quarantine + rebuild the cache (delete the cache volume, restart — it
  rematerializes from the manifest). Check disk first.

## Disk full

- **Signals:** `offloader_cache_disk_free_bytes` low; materialization fails.
- **Owner:** customer environment.
- **Action:** grow the cache volume or clear old snapshots, then restart.

## Pool busy / endpoint latency regression — sizing the read pool

- **Signals:** rising p95/p99 (benchmark harness / your APM); `offloader_pool_busy`
  sustained near `offloader_pool_connections`; `DIAG` `pool`.
- **Owner:** Offloader (serving) or customer (load / sizing).
- **Action:** classify the bottleneck first, then size for it — the right pool size
  depends on the workload and serving mode, not a single number. Baseline against
  [`benchmarks.md`](../benchmarks.md).
  - **Cache hits dominate** (stable params + `cache.policy: snapshot`): a hit serves a
    precomputed, pre-encoded body and barely touches the pool, so pool size is a non-issue
    — turn caching on. Latency here is CPU/payload, not the pool.
  - **`local_table` misses, high concurrency:** a materialized read is a fast in-memory
    query, so throughput scales cleanly with the pool — raise `OFFLOADER_POOL_SIZE` (and CPU
    to match). Measured on a 4-vCPU box, a 128-connection pool served the whole suite with
    zero errors where a 16-connection pool was shedding `503`s. This is the main throughput knob.
  - **`remote_scan` misses:** each read waits on the object store, so a large pool of them
    thrashes the box — a burst of fat-endpoint misses can push tail latency into seconds. Do
    NOT chase it by raising the pool; `OFFLOADER_REMOTE_SCAN_CONCURRENCY` (default
    `min(pool_size, 16)`) caps them for exactly this reason. Scale **out** (more replicas)
    instead, move a hot endpoint to `local_table`, or make the source Parquet prunable
    ([architecture](../architecture.md#getting-the-most-from-remote_scan)).
  - **Multi-MB payloads:** bandwidth-bound on the response write, not the pool — paginate or
    lower the endpoint's `limit`; more connections won't help.
- **Rule of thumb:** start at the default 16; scale the pool up for `local_table` throughput,
  scale replicas out for `remote_scan` and availability.

## Tenant/auth misconfiguration / key or auth failures

- **Signals:** consumers get 401 (bad/revoked key) or 404 (endpoint not granted).
- **Owner:** customer (key config).
- **Action:** confirm the key's `status: active`, its `endpoints` allowlist, and its
  bound `tenant` in `keys.yml`. 404 is intentional for out-of-scope endpoints (no
  existence disclosure). Mint keys with `offloader keys create`.

## Rollback to previous image

- **Owner:** customer.
- **Action:** redeploy the previous pinned image tag. Health returns immediately;
  there is no migration to undo.

## Rollback to previous snapshot

- **Owner:** customer/Offloader.
- **Action:** a bad snapshot never swaps in (validation + compatibility gate it). To
  revert a good-but-wrong snapshot, roll the dataset back to its previous good one.

## Cache quarantine and rebuild / clear cache

- **Owner:** customer.
- **Action:** stop the container, remove the cache volume (one dataset: remove its
  materialized files; all: the whole volume), restart. The server rematerializes
  from the current manifest on boot.
