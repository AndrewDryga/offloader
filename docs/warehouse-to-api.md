# Serve a warehouse-backed API from snapshots

If your API can return data that is minutes or hours old, serve it from a
warehouse snapshot instead of querying the warehouse on every request.

Customer dashboards that show usage totals, billing totals, or leaderboards are
typical candidates. This guide walks through moving one customer usage endpoint to
Offloader. Your pipeline exports the data, and Offloader serves it through a REST
API on your own servers.

**Before you start:** choose one existing endpoint and decide how old its data
can be. The [quickstart](quickstart.md) supplies the container and sample data for
trying the API locally with Docker and Git.

## 1. Choose what the endpoint returns

List the fields your screen needs and the filters callers may use. For customer
data, identify the column that separates one customer's rows from another's.

The bundled
[`customer_usage_summary` definition](../examples/customer-analytics/endpoints/customer_usage_summary.yml)
groups usage by account. It accepts `from`, `to`, and an optional `account_id`,
and returns four columns: account ID, active users, API calls, and average storage.

Callers supply filters, never SQL. The API key identifies the tenant, and Offloader
adds the tenant filter to the query. The date range filters rows in the current
snapshot; it does not select an older snapshot.

## 2. Publish a complete snapshot

Export the dataset to Parquet, including the tenant column and every field the
endpoint needs. A small JSON file called a **manifest** lists the files and schema
for that snapshot. It tells Offloader which files belong together, even if the
export directory contains several versions.

Your pipeline owns the export schedule. Offloader loads the result and checks it
before serving it. How you publish updates depends on the dataset configuration.

### If you use `manifest:`

A static manifest lives inside the project. Offloader does not poll it for updates.
To publish an update through config sync:

1. Write the new data files and a manifest with a new `snapshot_id`.
2. Update the dataset YAML to point to the new manifest.
3. Let enabled config sync load the change. If sync is off, restart Offloader
   with the updated project.

Replacing only the JSON or Parquet files does not trigger config sync.

### If you use `source:`

Offloader can discover supported exports on its refresh schedule. For example,
the Databricks source uses completed export metadata to find the files.

See the [configuration reference](config-reference.md) for both options.
Offloader does not schedule warehouse exports for you.

## 3. Call the sample endpoint

Follow the [quickstart](quickstart.md) to run the container and wait for it to
be ready. Then call the sample endpoint with its demo key:

```sh
curl -H "Authorization: Bearer offl_demo_acme_key" \
  "http://localhost:4000/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01"
```

Check the `data` rows and the `meta` fields:

- The rows should belong to the tenant named by the key.
- `snapshot_id` identifies the snapshot that answered the request.
- The freshness `watermark` tells you when the data was current.
- `stale: true` means the data is older than the configured limit. That is expected
  for this old sample data. **Offloader still serves it**; your app decides whether
  to accept it.

Try adding a `tenant_id` parameter. This endpoint does not accept it, so the
request returns `422 invalid_param`, as shown in the quickstart. Before serving
real customers, test with separate tenants and check each key's results.

## 4. Compare it with your current API

Replay a realistic set of requests against both APIs, using non-sensitive data
from the same point in time. Check that the results match, including empty
responses, date boundaries, and pagination. Test a failed refresh too: requests
should keep using the last working snapshot.

Under the load you expect, measure response times, errors, refresh time, and data
age. The [benchmark guide](benchmarks.md) shows how to run those checks.

For cost, start with warehouse compute you can actually remove. Subtract export,
storage, serving, and license costs. If you pay for reserved warehouse capacity,
fewer queries may not lower the bill until you downsize. The
[ROI calculator](https://offloader.dryga.com/roi.html) gives an initial estimate;
it does not include every running cost.

You should now know whether this endpoint returns the right data, stays fresh
enough, and saves enough to justify the move. Read the
[security model](security-model.md) and [deployment guide](deployment.md) before
exposing it. If snapshots do not fit, compare
[direct queries and response caching](warehouse-cache-or-snapshot.md).
