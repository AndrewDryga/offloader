# What Offloader is (in plain language)

New here? Read this first. It explains what Offloader does, why you'd want it, and
the handful of words the rest of the docs use — no prior data-engineering knowledge
assumed.

## The problem it solves

Your product has screens that show analytics: usage dashboards, leaderboards, "top
accounts," stats pages. Every time a user opens one, your app runs a query against
your **data warehouse** (Snowflake, Databricks, BigQuery, …). Warehouses are great
for crunching huge data, but they are **expensive per query** and **not fast enough**
to sit directly behind a busy product screen. So you end up paying a lot, and users
wait.

Here's the thing: those product screens ask the **same shapes of questions over and
over** ("usage for account X over the last 30 days"), against data that only needs to
be **a few minutes or hours fresh** — not up-to-the-second.

## What Offloader does

Offloader serves those repeated questions from **cheap, pre-computed copies of the
data** instead of hitting the warehouse every time.

```text
BEFORE:  every request  ->  data warehouse   ($$$ per query, too slow for a live screen)

AFTER:   every request  ->  Offloader        (cheap, fast) -> reads a pre-computed
                                              snapshot you publish to object storage
                                              (S3 / GCS), running on YOUR servers
```

You publish periodic **snapshots** of the data to object storage. Offloader loads a
snapshot into a fast local engine and answers your product's REST calls from it. When
a newer snapshot appears, it swaps over — with no downtime. The warehouse is only
touched by the pipeline that builds snapshots (on a schedule you control), not by live
traffic.

It runs as a **single container on your own infrastructure**: there's no Offloader
cloud, and your private data never leaves your environment.

## Is it a fit?

| Good fit if… | Not a fit if… |
| --- | --- |
| The same query shapes repeat a lot | Every query is different / ad-hoc SQL |
| "A few minutes/hours old" is fine | You need up-to-the-second data |
| You can export snapshots to S3/GCS | You can't produce snapshots |
| You want to cut warehouse serving cost | Native warehouse acceleration already solves it |

## The words we use

You only need these dozen terms to read the rest of the docs.

| Term | In one sentence |
| --- | --- |
| **Object storage** | Cloud file storage — Amazon **S3** or Google **GCS**, where your snapshot files live. |
| **Snapshot** | One frozen copy of a dataset at a point in time (Parquet files), e.g. "usage as of 3 PM today." |
| **Parquet** | A compact columnar file format snapshots are stored in; you don't edit these by hand. |
| **Manifest** | A small JSON file that says "this snapshot = these files, this schema, this version" — the pointer Offloader follows. |
| **Dataset** | A named table Offloader serves (e.g. `customer_usage`), plus the columns it expects. |
| **Endpoint** | A named REST URL your app calls (e.g. `/v1/endpoints/customer_usage_summary`), defined by a small config file. |
| **Project** | Your whole configuration: one `offloader.yml` plus `datasets/`, `endpoints/`, and `keys/` files. This is what Offloader loads at startup. |
| **Materialize** | Loading a snapshot's Parquet into Offloader's local engine (DuckDB) so reads are fast. Happens automatically. |
| **Refresh** | Checking for a newer snapshot and swapping to it. Automatic, on a schedule. |
| **Freshness / watermark** | How old the data is; the `watermark` is the snapshot's timestamp. Every response tells you. |
| **Tenant** | One customer/account in a multi-customer table; Offloader makes sure a caller only sees their own tenant's rows. |
| **API key** | A secret token a caller sends to use an endpoint; you can scope it to specific endpoints and one tenant. |

Two more you'll see in operations:

- **DuckDB** — the small, fast engine embedded inside the container that runs the queries. You don't install or manage it; it's just there.
- **Serving mode** — where a query reads from: a pre-loaded local table (`local_table`, the fast default) or straight from the snapshot files (`remote_scan`, for big/cold data). Most endpoints use the default.

## How the pieces fit

```text
  Your pipeline            Object storage (S3/GCS)       Offloader container        Your app
  (on your schedule)                                     (on your servers)
  ----------------         -----------------------       ------------------         --------
  warehouse --export-->  snapshot Parquet + manifest  -->  loads the latest    -->  GET /v1/endpoints/...
                                    ^                       snapshot into DuckDB,    (fast, cheap)
                                    |                       serves REST
                         (a newer snapshot appears)  ---->  auto-refresh, zero-downtime swap
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
- **[Replace an existing serving API](cutover-runbook.md)** — the safe, gradual switch-over.
