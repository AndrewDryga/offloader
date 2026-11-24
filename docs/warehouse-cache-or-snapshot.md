# Serving customer dashboards: warehouse queries, a cache, or snapshots?

Customer dashboards can query the warehouse, reuse responses from a cache such as
Redis, or read a published dataset through Offloader.

Choose based on how fresh the data must be and how often requests repeat. A cache
may be enough. With snapshots, customer requests no longer query the warehouse,
but you pay to export the data and run the API.

| | Direct queries | Response cache | Offloader snapshots |
| --- | --- | --- | --- |
| Reads from | The warehouse | A saved response | A published dataset |
| On a cache miss | Queries the warehouse | Calls your existing API | Queries the snapshot |
| Freshness depends on | Warehouse ingestion | Expiry and invalidation | Exports and refreshes |
| You manage | Warehouse and app | Existing API plus cache | Export pipeline and container |

## Keep direct queries for fresh data or ad-hoc questions

A screen that must reflect a just-completed transaction may not tolerate a
snapshot delay. Exploratory queries may also need more freedom than a fixed set
of endpoints allows. Measure your current API first: query optimization or
warehouse acceleration may solve the problem without another service.

Check the options your warehouse already offers. [BigQuery's query cache](https://docs.cloud.google.com/bigquery/docs/cached-results)
can reuse eligible query results, and [BI Engine](https://docs.cloud.google.com/bigquery/docs/bi-engine-intro)
accelerates supported queries. [Snowflake Interactive Analytics](https://docs.snowflake.com/en/user-guide/interactive)
is built to handle many application queries at once with low latency. Test these
options with your own queries and compare the speed, data age and bill.

## Use a cache when the same requests repeat

A cache can be a smaller change when callers often ask the same question and you
know when saved answers should expire. Include everything that changes the answer
in the cache key, including the caller's permissions and tenant. Test cache
misses and cold starts as well as hits.

If users vary filters enough that most requests miss, the warehouse may still do
most of the work. Check your hit rate before changing the architecture. A
snapshot API adds export and operating costs, so compare the full cost of both
approaches.

## Use snapshots when many requests can share one dataset

Your export job produces the snapshot. Offloader answers REST requests from it,
without querying the warehouse for each request. This suits APIs with known
fields and filters whose data can wait for the next export and refresh.

You run the service and monitor its capacity, exports, and data age. Offloader
marks old responses as `stale`, but keeps serving them. Your app decides what to
do when the data is too old. Try the
[warehouse-to-API walkthrough](warehouse-to-api.md) with one of your endpoints.

You can use caching with snapshots too. Offloader's response cache distinguishes
endpoint versions, tenants, parameters, and snapshot IDs, so a response from an
older snapshot does not get reused after an update.

## When a serving database is a better fit

If you already keep small summary tables in Postgres, your application may be able
to serve them directly. For continuously arriving data or a wider range of
analytical queries, consider a database such as ClickHouse. Offloader serves REST
endpoints you define over published Parquet datasets. Callers use the filters you
allow, rather than sending arbitrary SQL.

## Compare one real endpoint

Use the same data, freshness requirement, and realistic requests for each option.
Check:

- Do the results match, and can each customer read only their own data?
- How fast are typical and slow requests? What happens on errors or a cold start?
- How often does the cache help, how long do refreshes take, and how old is the data?
- Which warehouse costs disappear? What do exports, storage, servers, licenses,
  and operating time add?

In our [100-request dashboard replay](benchmarks.md#how-often-does-a-dashboard-query-the-source),
a response cache needed 24 source queries. Offloader used two full exports.
Your busiest dashboard may have a very different mix of repeat views and new
filters. Use the [cost worksheet](benchmarks.md#compare-the-full-cost) to price
those reads and exports with your own numbers. If your warehouse runs on reserved
capacity, the bill may stay the same until you can downsize it.

The [cache check](cache-check.md) tests how Offloader handles tenant data, rejected requests and
stale responses when you turn on its own cache. To try it with the bundled
project, start with the [quickstart](quickstart.md). For a monthly estimate, enter
your workload in the [ROI calculator](https://offloader.dryga.com/roi.html).
