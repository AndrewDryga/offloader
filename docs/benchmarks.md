# Benchmarking

The harness measures the pre-pilot performance gate: cold/warm load, memory, disk,
and p50/p95/p99 latency at concurrency 1, 10, and 50.

## Run it

```sh
./dev/scripts/benchmark.sh [out_dir]
# short CI run (default 300 req/scenario); deeper manual run:
BENCH_REQUESTS=5000 ./dev/scripts/benchmark.sh ./bench-out
```

It boots the gateway in `MIX_ENV=prod` against `examples/customer-analytics` with a
temp cache, times the cold boot to `/ready`, runs the load, restarts to time a warm
boot, and writes `summary.json` + `summary.md`. Mode comparison (local_table vs
remote_scan) is in `dev/scripts/bench-modes.exs`.

## What each number means

- **cold_load_ms / warm_load_ms** — process start until `/ready` returns 200 (the
  snapshot is materialized and the instance can serve). Warm reuses the on-disk
  cache and the DuckDB extension cache.
- **rss_mb / cache_disk_bytes** — resident memory and materialized-cache footprint.
- **scenarios** — `local_table` varies a param per request so every read is a fresh
  materialized-table query (cache miss); `cache_hit` repeats identical params to
  exercise the response cache. Each is measured at concurrency 1/10/50 with
  p50/p95/p99/max latency (ms) and requests/sec.

## How to read it

- Watch **p95/p99 at concurrency 50**, not the average — tail latency is what a
  product API is judged on.
- A large `local_table` vs `cache_hit` gap means the response cache is earning its
  keep for repeated params.
- Reads run through the DuckDB connection pool (`OFFLOADER_POOL_SIZE`) in the caller
  process, so throughput scales with the pool rather than a single connection.

## Prod-scale run (real data, 2026-07-02)

A full production serving schema converted with `offloader import-schema`
(**66 datasets / 67 endpoints**), booted in `MIX_ENV=prod` against the **real GCS
bucket** (OAuth bearer), `OFFLOADER_POOL_SIZE=32`, `OFFLOADER_DUCKDB_MEMORY_LIMIT=6GB`,
`OFFLOADER_DUCKDB_THREADS=6` on an Apple-silicon laptop.

- **Cold start:** ~9–10 min to all 66 datasets `ready` — a sequential
  materialize-from-GCS of every table (the slowest have 30+ parquet parts). One
  slow/failing dataset no longer blocks or crashes boot (see below); it records a
  failed attempt and the rest serve. Warm restart is instant (on-disk snapshots +
  sidecar).
- **Steady-state RSS:** ~4.0 GiB resident with all 66 tables materialized (bounded by
  `OFFLOADER_DUCKDB_MEMORY_LIMIT`; peaks higher mid-materialize, then DuckDB releases).
- **Serving (cached, ~50 KB nested-JSON payloads), c=100, 40k requests:** **5.2k
  req/s, 0 failures**, p50 14 ms / p95 26 ms / p99 35 ms, ~290 MB/s transferred.
- **Correctness:** every endpoint served its current snapshot (the resolver follows
  the latest Databricks commit); zero refresh errors across 66 datasets.
- **Boot resilience:** a materialize that exceeds its budget, or a down engine, returns an
  error at the engine boundary instead of crashing — so one slow or broken dataset can neither
  crash startup nor wedge a refresh worker; it records a failed attempt and the rest serve.

`/metrics` exposes `offloader_pool_connections` / `offloader_pool_busy` and, per
endpoint, `offloader_requests_total{status}` plus an `offloader_request_duration_ms`
histogram.

## Honesty

The **latency and throughput** numbers here come from a fixed nested-JSON payload on a
single machine — **relative only**, not the prod-scale cold-boot validation above. Don't
quote them as a production SLA: real latency and savings require a pilot benchmark on the
customer's own data and hardware.
