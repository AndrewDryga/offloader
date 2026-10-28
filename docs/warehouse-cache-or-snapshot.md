# Warehouse queries, a cache, or snapshots?

Use direct warehouse queries for fresh or ad-hoc data, a response cache for
repeated requests, and snapshots when many requests can share one dataset.

The right choice depends on how fresh the data must be, which requests repeat,
and what those requests cost. A cache may be enough. A snapshot API can remove
warehouse queries from the request path, but adds exports and a service you need
to run.

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

## Compare one real endpoint

Use the same data, freshness requirement, and realistic requests for each option.
Check:

- Do the results match, and can each customer read only their own data?
- How fast are typical and slow requests? What happens on errors or a cold start?
- How often does the cache help, how long do refreshes take, and how old is the data?
- Which warehouse costs disappear? What do exports, storage, servers, licenses,
  and operating time add?

Reserved capacity and shared workloads can keep the warehouse bill unchanged
even after you remove queries. Compare invoices as well as query counts. The
[benchmark guide](benchmarks.md), [quickstart](quickstart.md), and
[ROI calculator](https://offloader.dryga.com/roi.html) help you test the options.
