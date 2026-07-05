# Config guide — publish your datasets and endpoints

The reference for the config files Offloader loads. New to the ideas here (dataset,
endpoint, snapshot, manifest, project)? Read
[What Offloader is, in plain language](concepts.md) first.

## A project is just files

Your configuration — your **project** — is a small tree of YAML:

```text
offloader.yml       # top level: which dirs to load, the auth mode, the keys file
datasets/*.yml      # one per dataset: the table + the columns you expect
endpoints/*.yml     # one per endpoint: the REST URL, its params, query, and limits
keys/keys.yml       # API keys (stored as hashes) — omit entirely for a public API
```

Offloader loads this at startup from `OFFLOADER_CONFIG` — either a **mounted directory**
(point it at `.../offloader.yml`) or, fully stateless, a **`gs://…` or `s3://…` bucket prefix**
(fetched at boot — see [Config from object storage](#config-from-object-storage-optional)).
Nothing is baked into the image.

To see a complete, working project, run the **[Quickstart](quickstart.md)** against
`examples/customer-analytics/` — it boots a container and serves a real endpoint in about
15 minutes. Copy that example and edit it.

## The `offloader` CLI (optional)

The `offloader …` commands in this guide are an **optional helper**, not part of the container —
the container itself needs only the files above plus env vars. Install it once (every command,
with flags, is in the **[CLI reference](cli.md)**):

```sh
curl -fsSL https://offloader.dryga.com/install.sh | sh   # or from source: cd tools && go build -o offloader .
```

## Start a new project (scaffold)

Authoring the YAML by hand is the slow part, so the CLI (above) scaffolds it for you.

```sh
# A complete, valid, fully-commented starter project — every field is commented
offloader init --out my-project

# …the same, but a public (no-auth) project
offloader init --out my-project --public

# Draft a dataset schema by reusing a snapshot manifest's schema
offloader scaffold-dataset --from data/events/manifest.json --tenant-column tenant_id

# …or infer the column types from a CSV sample
offloader scaffold-dataset --from sample.csv --id events --out my-project/datasets/events.yml
```

`init`'s output passes `offloader validate` as-is; you then point each dataset's
`manifest:` at your snapshot and adjust the endpoint. The full field reference is
[config-reference.md](config-reference.md).

## Container env vars

You only have to set **two**:

- `OFFLOADER_CONFIG` — path to `offloader.yml`, or a `gs://…`/`s3://…` bucket prefix.
- `OFFLOADER_SECRET_KEY_BASE` — any random string (`openssl rand -base64 48`).

Everything else has a sensible default:

- `OFFLOADER_CACHE_DIR` (default `/var/lib/offloader/cache`), `OFFLOADER_API_PORT` (4000),
  `OFFLOADER_ADMIN_PORT` (4001), `OFFLOADER_LOG_LEVEL` (info).
- `OFFLOADER_ADMIN_TOKEN` — recommended: gates the `/diagnostics` route (unset ⇒ it fails closed).
- `OFFLOADER_CONFIG_SYNC_INTERVAL` — seconds between bucket config re-checks (unset ⇒ off).
- `OFFLOADER_CORS_ORIGINS` — allow a browser front-end to call the API cross-origin: `*` or a
  comma-separated origin list (unset ⇒ no CORS). See [serving public data](public-serving.md).
- Tuning: `OFFLOADER_POOL_SIZE` (DuckDB read connections, default 16),
  `OFFLOADER_REMOTE_SCAN_CONCURRENCY` (max concurrent `remote_scan` reads, default
  `min(pool_size, 16)` — caps slow object-store reads so they can't starve the pool of fast
  `local_table` queries; see [architecture](architecture.md#getting-the-most-from-remote_scan)),
  `OFFLOADER_DUCKDB_THREADS` / `OFFLOADER_DUCKDB_MEMORY_LIMIT` (bound DuckDB to the container's
  memory allocation), `OFFLOADER_CACHE_MAX_ENTRIES` (response-cache entry ceiling, default
  10,000 — raise it for more distinct query shapes, lower it to cap cache memory).

Object-store credentials are needed only when your config reads from a remote source (below);
the local example needs no cloud vars and makes no outbound calls.

### Remote snapshot credentials (optional)

Needed only when a snapshot's `files[].path` is an `s3://`, `gs://`, or `https://` URL
(DuckDB reads it directly). Pick the mode that matches where the data lives.

**AWS S3 / S3-compatible.**

- *Static keys:* `OFFLOADER_S3_TYPE=s3`, `OFFLOADER_S3_KEY_ID`, `OFFLOADER_S3_SECRET` (plus
  `OFFLOADER_S3_REGION`; for a non-AWS store also `OFFLOADER_S3_ENDPOINT` /
  `OFFLOADER_S3_URL_STYLE` / `OFFLOADER_S3_USE_SSL`).
- *No static keys on AWS:* `OFFLOADER_S3_AUTH=chain` uses DuckDB's credential chain — env,
  `~/.aws`, and the **EC2/EKS instance role via IMDS** — so a pod reads `s3://` under its IAM
  role with nothing baked in.

**Google Cloud Storage.**

- *OAuth (recommended):* `OFFLOADER_GCS_AUTH=bearer`. Offloader finds a token in order —
  `OFFLOADER_GCS_TOKEN` if set, else the **GCE/GKE metadata server** (the production path, no
  config at all), else the `gcloud` CLI (dev laptops) — and refreshes it before it expires.
- *HMAC:* `OFFLOADER_S3_TYPE=gcs` with `OFFLOADER_S3_KEY_ID` / `OFFLOADER_S3_SECRET` (GCS's
  S3-interoperability keys).

**Public bucket — no credentials.** `OFFLOADER_GCS_AUTH=none` (or `anonymous` / `public`) reads
a public `gs://` bucket unauthenticated; a `401/403` is then surfaced, not retried. Public data
served over `https://` needs no credential vars at all.

Explicit HMAC keys win when both are set. Credentials never appear in logs, error bodies, or
support bundles — values are scrubbed and bundles are redacted.

## Sources & refresh

A dataset gets its data one of two ways, chosen per dataset:

- **A static `manifest:`** — you publish each snapshot: write the Parquet plus a manifest
  carrying a new `snapshot_id`, then point the dataset at it. A running container picks up a
  new `snapshot_id` at **boot**, on a **manual/admin refresh**, or when **config auto-sync**
  reloads the config (below). This is the path for any warehouse that can export Parquet —
  Snowflake, BigQuery, Redshift, a Spark job.
- **A remote `source:`** — the container discovers the newest snapshot itself and swaps it in
  on a poll (`source.interval_seconds`), hands-off. The shipped connector is **Databricks**
  (it resolves the latest committed snapshot in the bucket); other warehouses use the
  static-manifest path above.

Either way the swap is validated and zero-downtime: a snapshot that fails its dataset
contract is rejected and the last good one keeps serving.

## The cache directory (warm vs. cold restarts)

`OFFLOADER_CACHE_DIR` (default `/var/lib/offloader/cache`) is where a `local_table` dataset's
snapshot is **materialized** — the on-disk DuckDB copy that requests actually read from. It is a
**cache, not the source of truth**: the bucket is. You can delete it at any time and lose nothing
but warm state — the container rebuilds it from the manifest on the next boot or refresh.

That rebuild is the whole reason to persist it. Mount a volume at the cache dir (as the
[README run command](../README.md#runtime-configuration) does) and a restart is a **warm start**:
the materialized snapshot is already on disk, so the container serves within seconds. Leave it
ephemeral and every restart is a **cold start** — the container re-fetches every snapshot from
object storage and re-materializes it before it can serve, which on a large project is minutes,
not seconds. So in production, **persist it**:

- **Size the volume for your total materialized snapshot bytes, with headroom.** A refresh writes
  the new copy of a dataset before dropping the old one, so budget for the largest dataset being
  present twice during its swap.
- **It is disposable.** Losing the volume (a new host, a wiped disk) only forces one cold start;
  it never risks data, because the bucket is authoritative.

**If a dataset is too large to materialize on the box, don't size the disk to it — serve it
remotely.** Set that endpoint's [`serving_mode: remote_scan`](config-reference.md#endpointsyml) and
DuckDB scans the snapshot's Parquet **directly from object storage per request** — nothing is
copied into the cache dir. You trade a little per-request latency for not needing local disk (or a
cold-start rematerialization) proportional to the dataset. It's the right mode for huge, cold, or
low-QPS endpoints; keep `local_table` (the default) for the hot ones.

## Config from object storage (optional)

`OFFLOADER_CONFIG` may be a **`gs://bucket/prefix/` or `s3://bucket/prefix/` URL** instead of a
mounted path. At boot Offloader fetches the whole project tree (`offloader.yml`, `datasets/`,
`endpoints/`, the keys file) into `<cache_dir>/config/` and loads it from there — so the container
is fully stateless: env vars in, config and data both in the bucket, nothing mounted. With
`OFFLOADER_CONFIG_SYNC_INTERVAL` set it keeps watching the prefix and **hot-reloads any change
with no restart** (see [Hot config auto-sync](#hot-config-auto-sync) below).

Host your `offloader.yml` (and its `datasets/`/`endpoints/`/`keys/` tree) under a `gs://…` prefix
and boot the published image straight against it — the only volume is the optional
[warm-start cache](#the-cache-directory-warm-vs-cold-restarts):

```sh
docker run \
  -e OFFLOADER_CONFIG=gs://your-bucket/offloader/ \
  -e OFFLOADER_GCS_AUTH=bearer \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e OFFLOADER_CACHE_DIR=/var/lib/offloader/cache \
  -v offloader-cache:/var/lib/offloader/cache \
  -p 4000:4000 \
  -p 127.0.0.1:4001:4001 \
  ghcr.io/andrewdryga/offloader:edge   # or pin a release, e.g. :0.1.4
```

On GKE/GCE the bearer token comes from the metadata server (no credential env needed); on a
laptop it falls back to `gcloud`. Add `OFFLOADER_CONFIG_SYNC_INTERVAL` and edits you publish to
the prefix hot-reload with no restart (below).

- **`gs://`** uses the GCS bearer token chain (`OFFLOADER_GCS_TOKEN`, the GCE metadata server, or
  `gcloud` — set `OFFLOADER_GCS_AUTH=bearer`), or **no credentials** with `OFFLOADER_GCS_AUTH=none`
  for a public bucket. **`s3://`** is also supported — SigV4-signed with the `OFFLOADER_S3_*`
  credentials (or anonymous for a public bucket; `OFFLOADER_S3_ENDPOINT` targets an S3-compatible
  store). (`https://` config is not supported.)
- The whole project tree under the prefix is fetched — the config `.yml` **and** its companion
  data (a static `manifest.json` + the small snapshot files a relative `manifest:` points at) —
  bounded to 500 files / 32 MiB, so a self-contained project boots straight from the bucket. A
  transient error at boot is retried a few times; an invalid config fails boot loudly, exactly as
  a bad mounted config does.
- Datasets served from a remote config should use a remote `source:` (Databricks/GCS) or an
  absolute/remote `manifest:` — a *relative local* `manifest:` has no mounted data to resolve
  against.
- **Security — co-hosting config with data:** the keys file stores **SHA-256 hashes of bearer
  tokens, never the tokens** (see `security-model.md`), so bucket-read exposure leaks hashes plus
  the endpoint/tenant access map, not usable credentials. A **public** deployment (`auth: none`)
  has no keys file at all — the cleanest stateless setup. For an authed deployment, put the config
  under a **separate, tighter-ACL bucket/prefix** from the bulk data if you want to limit who can
  read the hashes.

### Hot config auto-sync

Set `OFFLOADER_CONFIG_SYNC_INTERVAL=<seconds>` (unset/0 = off) and Offloader re-checks the config
on that interval and hot-reloads changes **with no restart**:

- Change detection is cheap — a single object LIST (no downloads) when nothing changed.
- Endpoint, key, and data-source changes apply at once (the response cache is flushed).
- A dataset **schema** change is applied **blue-green with zero downtime**: the old snapshot and its
  endpoints keep serving while the new-schema table is materialized off to the side, then that
  dataset's table and endpoints flip together atomically. A staged build that fails compatibility
  (e.g. the producer hasn't published matching data yet) keeps the old version serving and is
  retried — nothing it serves ever breaks.
- A bad sync (network, invalid YAML, validation error) is logged and the **running config is kept** —
  a broken bucket revision never takes the service down.
- `/metrics` exposes `offloader_config_sync_enabled` and `offloader_config_sync_ok` (alert on the
  latter == 0); admin `/diagnostics` shows the last sync result + timestamps.

Push a new revision the boring way: update the objects under the config prefix and the next tick picks
them up. Sequence a schema change as **data first, then config**, so the new-schema build succeeds on
the first try.

## Where to go next

- The **[CLI reference](cli.md)** — every `offloader` command, its flags, and an example.
- The **[config reference](config-reference.md)** — every field of every config file.
- A complete working project to copy: `examples/customer-analytics/`.
