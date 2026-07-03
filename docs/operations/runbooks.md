# Runbooks

One short runbook per V1 incident class. The first job is **classification** — is
this an Offloader bug, the customer environment, or upstream data? The admin
`/diagnostics` and `/metrics` answer that in under five minutes. Each runbook:
symptom → signals → likely owner → action → escalation.

> Commands assume the admin port is reachable privately and `OFFLOADER_ADMIN_TOKEN`
> is set. `DIAG` below means `curl -H "Authorization: Bearer $TOKEN" $ADMIN/diagnostics`.

## Gateway does not start

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

## Pool busy / endpoint latency regression

- **Signals:** rising p95/p99 (benchmark harness / your APM); `DIAG` `pool`.
- **Owner:** Offloader (serving) or customer (load).
- **Action:** compare against a benchmark baseline (`../benchmarks.md`). For a hot,
  high-QPS endpoint on `remote_scan`, move it to `local_table`. Consider the response
  cache for repeated params.

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
  materialized files; all: the whole volume), restart. The gateway rematerializes
  from the current manifest on boot.
