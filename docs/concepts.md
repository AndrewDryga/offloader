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

<figure class="flow flow-contrast" aria-label="Before: every request hits the data warehouse — billed per query and too slow for a live screen. After: every request hits Offloader on your servers, which reads from a pre-computed snapshot in object storage.">
  <div class="flow-lane">
    <span class="lane-tag lane-before">Before</span>
    <div class="flow-track">
      <div class="node"><span class="node-k">Every request</span><strong>Your app</strong></div>
      <div class="hop"><span class="hop-l">live query</span><span class="arw" aria-hidden="true"></span></div>
      <div class="node node-warn"><span class="node-k">Data warehouse</span><strong>$$$ · slow</strong><span class="node-sub">billed per query</span></div>
    </div>
  </div>
  <div class="flow-lane">
    <span class="lane-tag lane-after">After</span>
    <div class="flow-track">
      <div class="node"><span class="node-k">Every request</span><strong>Your app</strong></div>
      <div class="hop"><span class="hop-l">cached REST</span><span class="arw" aria-hidden="true"></span></div>
      <div class="node node-hero"><span class="node-k">Your servers</span><strong>Offloader</strong><span class="node-sub">cheap · fast</span></div>
      <div class="hop"><span class="hop-l">reads</span><span class="arw" aria-hidden="true"></span></div>
      <div class="node"><span class="node-k">Object store</span><strong>Snapshot</strong><span class="node-sub">S3 · GCS</span></div>
    </div>
  </div>
</figure>

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

<figure class="flow" aria-label="Your pipeline exports a snapshot (Parquet + manifest) to object storage on your schedule; Offloader loads the latest snapshot into DuckDB and serves REST; a newer snapshot triggers an automatic, zero-downtime swap.">
  <div class="flow-track">
    <div class="node node-batch"><span class="node-k">On your schedule</span><strong>Your pipeline</strong><span class="node-sub">warehouse export</span></div>
    <div class="hop hop-batch"><span class="hop-l">export</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node"><span class="node-k">Object store</span><strong>Parquet + manifest</strong><span class="node-sub">S3 · GCS</span></div>
    <div class="hop"><span class="hop-l">materialize</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node node-hero"><span class="node-k">Your servers</span><strong>Offloader · DuckDB</strong><span class="node-sub">loads the latest snapshot</span></div>
    <div class="hop"><span class="hop-l">REST</span><span class="arw" aria-hidden="true"></span></div>
    <div class="node"><span class="node-k">Every request</span><strong>Your app</strong><span class="node-sub">fast · cheap</span></div>
  </div>
  <figcaption class="flow-cap"><span class="flow-mark" aria-hidden="true">↻</span> A newer snapshot triggers an <b>automatic, zero-downtime swap</b> — the warehouse is only touched by the export, never by live traffic.</figcaption>
</figure>

## The two ports

Offloader listens on two ports, on purpose:

- **API port (4000)** — where your product traffic goes. Protected by API keys (unless you run it fully public). This is the only port your app or the internet should reach.
- **Admin port (4001)** — health checks, metrics, generated docs, diagnostics. For your operators only. **Keep it private** (internal network / firewall) — Offloader doesn't do logins; you control who reaches this port.

## Where to go next

- **[Quickstart](quickstart.md)** — run it against a bundled example in ~15 minutes, no cloud needed.
- **[Define your own endpoints](developer-experience.md)** — what the config files look like.
- **[Run it in production](operator.md)** — deploy, size, upgrade, roll back.
- **[Security](security-model.md)** — what's protected, and what you're responsible for.
