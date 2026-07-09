# What Offloader is (in plain language)

New here? Read this first. It explains what Offloader does, why you'd want it, and
the handful of words the rest of the docs use — no prior data-engineering knowledge
assumed.

## The problem it solves

Your product needs data the warehouse produces: usage meters, billing totals,
leaderboards, recommendations, customer analytics. A user is often waiting for that
answer. For example, your backend may need one account's usage, one customer's billing
total, or one leaderboard page before it can return an API response.

Warehouses (Snowflake, Databricks, BigQuery, and similar systems) are good at the
big job: crunching a lot of data and producing the answer set. They are a poor place
to send every small product API read. Each request can pay warehouse cost, inherit
warehouse latency, or depend on a cache your team built in a hurry.

Most of these APIs ask the same known questions over and over: "usage for account X
over the last 30 days," "top 50 leaderboard rows," "billing totals for this customer."
They usually need data that is 15-120 minutes fresh, not up-to-the-second.

## What Offloader does

Offloader lets your pipeline publish those answers as snapshots, then serves REST
endpoints from the snapshots on your own servers. The warehouse builds the data once.
Your app reads it many times until the next snapshot is ready.

```flow warehouse-vs-offloader
  Before
    Your app  ──warehouse query──▶  Data warehouse
                               $$$ · slow — billed per query

  After
    Your app  ──REST API──▶  Offloader  ──reads──▶  Snapshot
                                  your servers             S3 · GCS
                                  cheap · fast
```

You publish periodic **snapshots** of the data to object storage. Offloader checks the
snapshot, loads it into a fast local engine, and answers your product's REST calls from
it. When a newer snapshot appears, it switches to the new one without taking the API
down. If the new snapshot is bad, the last good one keeps serving.

It runs as a **single container on your own infrastructure**: there's no Offloader
cloud, and private data stays in your environment by default.

## Is it a fit?

| Good fit if… | Not a fit if… |
| --- | --- |
| Your app calls the warehouse while a user is waiting | It's an internal BI dashboard and the BI tool's cache/extracts already solve refresh |
| The same endpoint shapes repeat a lot | Every query is different / ad-hoc SQL |
| 15-120 minute freshness is fine | You need up-to-the-second data |
| You can export snapshots to S3/GCS | You can't produce snapshots |
| You want to cut warehouse serving cost | Native warehouse acceleration already solves it |

## The words we use

You only need these dozen terms to read the rest of the docs.

| Term | In one sentence |
| --- | --- |
| **Object storage** | Cloud file storage — Amazon **S3** or Google **GCS**, where your snapshot files live. |
| **Snapshot** | One frozen copy of a dataset at a point in time (Parquet files), e.g. "usage as of 3 PM today." |
| **Parquet** | A compact columnar file format snapshots are stored in; you don't edit these by hand. |
| **Manifest** | A small JSON file that says "this snapshot uses these files and this schema." Offloader follows that pointer. |
| **Dataset** | A named table Offloader serves (e.g. `customer_usage`), plus the columns it expects. |
| **Endpoint** | A named REST URL your app calls (e.g. `/v1/endpoints/customer_usage_summary`), defined by a small config file. |
| **Project** | Your whole configuration: one `offloader.yml` plus `datasets/`, `endpoints/`, and `keys/` files. This is what Offloader loads at startup. |
| **Materialize** | Load a snapshot's Parquet into Offloader's local engine (DuckDB) so reads are fast. Happens automatically. |
| **Refresh** | Check for a newer snapshot and switch to it. Automatic, on a schedule. |
| **Freshness / watermark** | How old the data is; the `watermark` is the snapshot's timestamp. Every response includes it. |
| **Tenant** | One customer/account in a multi-customer table; Offloader limits a caller to its own rows. |
| **API key** | A secret token a caller sends to use an endpoint; you can scope it to specific endpoints and one tenant. |

Two more you'll see in operations:

- **DuckDB** — the small, fast engine embedded inside the container that runs the queries. You don't install or manage it; it's just there.
- **Serving mode** — where a query reads from: a pre-loaded local table (`local_table`, the fast default) or straight from the snapshot files (`remote_scan`, for big/cold data). Most endpoints use the default.

## How the pieces fit

```flow snapshot-pipeline
  Your pipeline            warehouse export, on your schedule
        │ export
        ▼
  Object store             Parquet + manifest — S3 · GCS
        │ load locally
        ▼
  Offloader · DuckDB       your servers; loads the latest snapshot
        ▲
        │ REST
  Your app                 every request — no warehouse call

  ↻ A newer snapshot is checked before it replaces the old one. The warehouse is
    used by the export job, not by each customer request.
```

## The two ports

Offloader listens on two ports, on purpose:

- **API port (4000)** — where your product traffic goes. Protected by API keys (unless you run it fully public). This is the only port your app or the internet should reach.
- **Admin port (4001)** — health checks, metrics, generated docs, diagnostics. For your operators only. **Keep it private** (internal network / firewall) — Offloader doesn't do logins; you control who reaches this port.

## Where to go next

- **[Quickstart](quickstart.md)** — run it against a bundled example in ~15 minutes, no cloud needed.
- **[Define your own endpoints](developer-experience.md)** — what the config files look like.
- **[Run it in production](operator.md)** — deploy, size, upgrade, roll back.
- **[Security](security-model.md)** — what's protected, and what you're responsible for.
