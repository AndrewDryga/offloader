# Benchmarking

The harness measures cold/warm load, memory, disk, and p50/p95/p99 latency at concurrency
1, 10, and 50 — so you can size and tune Offloader on your own data before a pilot.

## Run it

```sh
./dev/scripts/benchmark.sh [out_dir]
# quick run (default 300 req/scenario); deeper run:
BENCH_REQUESTS=5000 ./dev/scripts/benchmark.sh ./bench-out
```

It boots the server in production mode against the bundled example with a temp cache, times the
cold boot to `/ready`, runs the load, restarts to time a warm boot, and writes `summary.json` +
`summary.md`. It can also compare serving modes (`local_table` vs `remote_scan`).

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

## What these numbers are (and aren't)

These latency and throughput figures come from a fixed nested-JSON payload on a single
machine, so treat them as **relative** — good for comparing modes and settings, not as a
production SLA. Your real latency and savings depend on your own data, payloads, and hardware:
measure them with a pilot benchmark before you commit.
