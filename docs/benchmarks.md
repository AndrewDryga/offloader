# Benchmarking

The benchmark script measures startup time, memory, disk use and p50/p95/p99
latency with 1, 10 and 50 concurrent requests. Use it to size and tune Offloader
on your own data before a pilot.

## Run it

```sh
./dev/scripts/benchmark.sh [out_dir]
# quick run (default 300 req/scenario); deeper run:
BENCH_REQUESTS=5000 ./dev/scripts/benchmark.sh ./bench-out
```

The script starts the server in production mode using the bundled example and a
temporary cache. It times startup until `/ready`, runs the requests, then restarts
the server to measure startup with a warm cache. Results go into `summary.json`
and `summary.md`. It can also compare `local_table` and `remote_scan` serving modes.

## What each number means

- `cold_load_ms / warm_load_ms`: time from process start until `/ready` returns
  200, when the snapshot is loaded and the server can answer requests. A warm
  start reuses the on-disk cache and DuckDB extension cache.
- `rss_mb / cache_disk_bytes`: process memory in RAM and disk space used by the
  snapshot cache.
- `scenarios`: `local_table` changes a parameter on every request, forcing a new
  query of the loaded table. `cache_hit` repeats the same parameters to test the
  response cache. Each runs at concurrency 1/10/50 and reports
  p50/p95/p99/max latency (ms) and requests/sec.

## How to read it

- Watch p95/p99 at concurrency 50 to see how slow requests behave under load.
  An average can hide delays your users notice.
- A large gap between `local_table` and `cache_hit` shows how much the response
  cache helps when the same request repeats.
- Reads run through the DuckDB connection pool (`OFFLOADER_POOL_SIZE`) in the caller
  process, so throughput scales with the pool rather than a single connection.

## What these numbers are (and aren't)

The bundled test uses a fixed nested-JSON response on one machine. Use its results
to compare modes and settings, not as a production SLA. Test with your own data,
responses and hardware to find out how fast the API will be and what it will cost.

For a small, repeatable first check, try [One endpoint, two cache settings](cache-check.md).

## Compare the full cost

Choose one customer dashboard endpoint and replay the same requests against direct
warehouse queries, a response cache, and Offloader. Keep the dataset, returned
fields, tenant permissions and acceptable data age the same. Include popular
requests and varied filters so the cache sees both hits and misses.

Save the test dates, software versions, machine size and request count with the
results. Run cold and warm tests separately. Check that responses match before
comparing speed.

| Measure | Direct warehouse | Response cache | Offloader |
| --- | --- | --- | --- |
| Successful requests, errors and timeouts | Record | Record | Record |
| p50 / p95 / p99 end-to-end latency | Record | Separate hits and misses | Separate hits and misses |
| Warehouse queries and billed usage | All queries | Misses and refreshes | Export queries |
| Data age seen by the caller | Record | Record | Record |
| Monthly compute cost | Warehouse + API | Warehouse + cache + API | Exports + serving hosts + app API |
| Monthly storage and transfer cost | Record | Record | Include snapshots and downloads |
| Setup and operating time | Record separately | Record separately | Include export failures and recovery |

Use your provider's bill to calculate costs. If you estimate a month from a short
test, show the traffic and refresh schedule you assumed. Fewer queries can free
warehouse capacity without reducing a bill you've already committed to. Report
measured usage, estimated monthly costs and actual savings separately.

Also test a failed refresh and a tenant trying to read another tenant's data.
Record what callers receive and how long recovery takes. The bundled benchmark
measures Offloader only. It does not run the warehouse or Redis comparisons for you.
