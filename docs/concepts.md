# How Offloader works

Offloader serves REST APIs from snapshots of your warehouse data. You run it on
your own servers, so your product can read the same data many times without
querying the warehouse for every request.

## The problem it solves

Your product needs data the warehouse produces: usage meters, billing totals,
leaderboards, recommendations, customer analytics. A user is often waiting for that
answer. For example, your backend may need one account's usage, one customer's billing
total, or one leaderboard page before it can return an API response.

Warehouses such as Snowflake, Databricks, and BigQuery process large datasets.
Calling them for every small API read can add cost and latency. A cache helps
when requests repeat, but its misses still reach the warehouse.

Most of these APIs ask the same known questions over and over: "usage for account X
over the last 30 days," "top 50 leaderboard rows," "billing totals for this customer."
A published snapshot fits only when its age stays within the product's freshness
requirement.

## What Offloader does

Offloader lets your pipeline publish those answers as snapshots, then serves REST
endpoints from the snapshots on your own servers. The warehouse builds the data once.
Your app reads it many times until the next snapshot is ready.

```flow warehouse-vs-offloader
  Before
    Your app  ──warehouse query──▶  Data warehouse
                               warehouse work per request

  After
    Your app  ──REST API──▶  Offloader  ──reads──▶  Snapshot
                                  your servers             S3 · GCS
                                  serving compute
```

Offloader checks each new snapshot, then loads it into DuckDB inside the
container. If an update fails, requests keep using the last working snapshot.

It runs as a **single container on your own infrastructure**: there's no Offloader
cloud, and private data stays in your environment by default.

Offloader is **source-available under the [Business Source License 1.1](../LICENSE)**,
not open source. Production use is free if your organization and its affiliates had
under $1M in total gross revenue in the last completed fiscal year. Larger
organizations need a commercial license for production use. This version's license
converts to Apache-2.0 on July 6, 2028; see the [license overview](../README.md#license).

## Is it a fit?

| Good fit if… | Not a fit if… |
| --- | --- |
| Your app calls the warehouse while a user is waiting | It's an internal BI dashboard and the BI tool's cache/extracts already solve refresh |
| The same endpoint shapes repeat a lot | Every query is different / ad-hoc SQL |
| Your freshness tolerance matches the export and refresh schedule | You need up-to-the-second data |
| You can publish consistent Parquet or CSV snapshots, locally or in supported object storage | You can't produce snapshots |
| You want to cut warehouse serving cost | Native warehouse acceleration already solves it |

## The words we use

These terms appear in the configuration and the guides.

| Term | In one sentence |
| --- | --- |
| **Object storage** | Cloud file storage — Amazon **S3** or Google **GCS**, where your snapshot files live. |
| **Snapshot** | One frozen copy of a dataset at a point in time (Parquet or CSV files), e.g. "usage as of 3 PM today." |
| **Parquet** | A compact columnar file format and the usual choice for snapshots; you don't edit these by hand. |
| **Manifest** | A JSON file identifying one snapshot's files and schema; a static manifest lives inside the project, while its data files can be remote. |
| **Dataset** | A named table Offloader serves (e.g. `customer_usage`), plus the columns it expects. |
| **Endpoint** | A named REST URL your app calls (e.g. `/v1/endpoints/customer_usage_summary`), defined by a small config file. |
| **Project** | Your whole configuration: one `offloader.yml` plus `datasets/`, `endpoints/`, and `keys/` files. This is what Offloader loads at startup. |
| **Materialize** | Load a snapshot's Parquet into DuckDB for `local_table` serving. |
| **Refresh** | Check a new snapshot and start serving it. How Offloader finds updates depends on your configuration. |
| **Freshness / watermark** | How old the data is; the `watermark` is the snapshot's timestamp. Each successful data response includes it. |
| **Tenant** | One customer/account in a multi-customer table; Offloader limits a caller to its own rows. |
| **API key** | A secret token a caller sends to use an endpoint; you can scope it to specific endpoints and one tenant. |

Two more you'll see in operations:

- **DuckDB** — the small, fast engine embedded inside the container that runs the queries. You don't install or manage it; it's just there.
- **Serving mode** — where a query reads from: a pre-loaded local table (`local_table`, the default) or straight from the snapshot files (`remote_scan`). Both load the data into DuckDB during refresh, so `remote_scan` doesn't save local disk. Measure your workload to choose.

## How the pieces fit

The default `local_table` request path:

```flow snapshot-pipeline
  Your pipeline            warehouse export, on your schedule
        │ export
        ▼
  Object store             Parquet + manifest — S3 · GCS
        │ load locally
        ▼
  Offloader · DuckDB       your servers; loads the configured snapshot
        ▲
        │ REST
  Your app                 every request — no warehouse call

  ↻ The default mode loads the configured snapshot into DuckDB. Your export job
    uses the warehouse; customer requests use the snapshot.
```

## How updates work

With a configured `source:`, Offloader can find supported exports on a schedule.
With a static `manifest:`, it loads the snapshot named by that file and does not
poll for updates.

To update a static manifest through config sync, publish the new data and a
manifest with a new `snapshot_id`. Then change the dataset YAML to point to it.
Enabled config sync loads that change; otherwise, restart with the updated
project. Changing only JSON or Parquet files does not trigger sync.

The [warehouse-to-API guide](warehouse-to-api.md#2-publish-a-complete-snapshot)
walks through both options. The [configuration reference](config-reference.md)
lists the settings.

## The two ports

Offloader listens on two ports, on purpose:

- **API port (4000)** — where your product traffic goes. Protected by API keys (unless you run it fully public). This is the only port your app or the internet should reach. If you turn it on, [AI agents](mcp.md) read the same endpoints through this port too, under the same keys.
- **Admin port (4001)** — health checks, metrics, generated docs, diagnostics. For your operators only. **Keep it private** (internal network / firewall) — Offloader doesn't do logins; you control who reaches this port.

## Where to go next

- **[Warehouse to API](warehouse-to-api.md)** — evaluate one product endpoint with concrete freshness and tenant checks.
- **[Choose a serving path](warehouse-cache-or-snapshot.md)** — compare direct queries, response caching and snapshots.
- **[Quickstart](quickstart.md)** — run it against a bundled example in ~15 minutes, no cloud needed.
- **[Define your own endpoints](developer-experience.md)** — what the config files look like.
- **[Run it in production](operator.md)** — deploy, size, upgrade, roll back.
- **[Serve it to AI agents](mcp.md)** — the same endpoints, readable by an assistant.
- **[Security](security-model.md)** — what's protected, and what you're responsible for.
