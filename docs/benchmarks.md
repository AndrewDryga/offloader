# Dashboard benchmarks

## How often does a dashboard query the source?

We replayed 100 requests for account usage totals. Direct queries read the source
100 times. A response cache cut that to 24. Offloader answered all 100 requests
from two exports, one for each version of the data.

| Serving path | Reads against the source | What the dashboard received |
| --- | --- | --- |
| Query on every request | 100 aggregate queries | Account totals for the requested tenant and dates |
| Cache each answer until the data changes | 24 aggregate queries | The same totals, with 76 requests served from cache |
| Publish a snapshot with Offloader | 2 full exports, 2,433 bytes each | The same totals, grouped by DuckDB for each request |

For each of two demo tenants, we requested the same three-day view 20 times
and five other date ranges once. Then we added 1,000 API calls to one Acme
account and ran the same 50 requests again. Acme’s three-day total went up by 1,000. Globex’s stayed
the same. All three paths returned matching account rows on every request.

The test uses SQLite as a local stand-in for a warehouse and a Python dictionary
as the response cache. At each update we emptied the cache and started Offloader
on the new CSV export before sending traffic. We checked the snapshot ID and
watermark on every response. This gives each path the same data and gives the
cache a reliable signal to expire old answers. To learn how long your users
might see old data during a refresh, time that separately on your own pipeline.

**Would the two exports cost less?** For each version, the cache ran 12 small
queries. The snapshot path read all 36 rows once. Compare the cost of that export
with the cost of those 12 queries, then add what each service costs to run.
A warehouse bill depends on the work each query does and how you pay for it.
This test used no paid warehouse.

### Repeat the comparison

From the repository root, with Python 3 and Docker running:

```sh
python3 dev/scripts/compare-dashboard-reads.py > dashboard-reads.json
```

The [replay script](../dev/scripts/compare-dashboard-reads.py) starts a local
Offloader container for each version and removes it afterward. It checks the rows
against the direct SQL result and stops on a mismatch.
[Download the November 24 UTC results](https://offloader.dryga.com/examples/dashboard-reads.json)
for every request, the fixture checksum, software versions and pinned image. The
timings cover the local Offloader HTTP calls. The direct and cached queries ran
inside Python, so we measured source reads across all three paths and timed only
the HTTP path.

To test your own endpoint, replay a day of requests including its busiest hour.
Write down how old its data can be, check a few known customer totals and price
each option with the [cost worksheet](#compare-the-full-cost).

## Run it

To measure startup, memory and request latency on your machine, run the load test.

```sh
./dev/scripts/benchmark.sh [out_dir]
# quick run (default 300 req/scenario); deeper run:
BENCH_REQUESTS=5000 ./dev/scripts/benchmark.sh ./bench-out
```

The script starts the server in production mode using the bundled example and a
temporary cache. It times startup until `/ready`, runs the requests, then restarts
the server to measure startup with a warm cache. Results go into `summary.json`
and `summary.md`.

## What each number means

- `cold_load_ms / warm_load_ms`: time from process start until `/ready` returns
  200, when the snapshot is loaded and the server can answer requests. A warm
  start reuses the on-disk cache and DuckDB extension cache.
- `rss_mb / cache_disk_bytes`: process memory in RAM and disk space used by the
  snapshot cache.
- `scenarios`: one set of requests varies the page offset, the other repeats the
  same request. Both run at concurrency 1, 10 and 50 and report throughput and
  p50, p95, p99 and maximum latency in milliseconds.

## How to read it

Check errors first, then look at p95 and p99 during the busiest run. With the
small demo dataset, most page offsets return no rows. Later rounds also reuse
offsets from the first round. A difference between the two sets of timings can
come from response size as well as caching.

For a [cache correctness check](cache-check.md), compare the same requests with
caching on and off. For a capacity decision, use an endpoint that returns as
much data as your customers actually read.

## Compare the full cost

Choose one customer dashboard endpoint and replay the same requests against direct
warehouse queries, a response cache, and Offloader. Keep the dataset, returned
fields, tenant permissions and acceptable data age the same. Include popular
requests and varied filters so the cache sees both hits and misses.

[Download the cost worksheet (CSV)](https://offloader.dryga.com/examples/dashboard-costs.csv)
to record all three options over the same period and in the same currency.
Save the test dates, software versions, machine size and request count with the results. Run cold and warm tests separately. Check that responses match before
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
