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
(point it at `.../offloader.yml`) or, fully stateless, a **`gs://…` bucket prefix**
(fetched at boot — see [Config from object storage](#config-from-object-storage-optional)).
Nothing is baked into the image.

To see a complete, working project, run the **[Quickstart](quickstart.md)** against
`examples/customer-analytics/` — it boots a container and serves a real endpoint in about
15 minutes. Copy that example and edit it.

## Start a new project (scaffold)

Authoring the YAML by hand is the slow part, so the CLI scaffolds it for you.

```sh
# A complete, VALID, fully-commented starter project (offloader.yml + one dataset,
# endpoint, and a working demo key). --public for a no-auth project.
offloader init --out my-project          # then edit it; every field is commented
offloader init --out my-project --public

# Draft a dataset's schema from something you already have, instead of hand-listing
# columns: reuse a snapshot manifest's schema, or infer types from a CSV.
offloader scaffold-dataset --from data/events/manifest.json --tenant-column tenant_id
offloader scaffold-dataset --from sample.csv --id events --out my-project/datasets/events.yml
```

`init`'s output passes `offloader validate` as-is; you then point each dataset's
`manifest:` at your snapshot and adjust the endpoint. The full field reference is
[config-reference.md](config-reference.md).

## The `offloader` CLI (optional)

The `offloader …` commands in this guide are an **optional Go helper**, not part of the
container. The container needs only the files above plus env vars. Build the helper once:

```sh
cd tools && go build -o offloader .     # then ./offloader <command>   (or: go run . <command>)
```

## Container env vars

You only have to set **two**:

- `OFFLOADER_CONFIG` — path to `offloader.yml`, or a `gs://…` bucket prefix.
- `OFFLOADER_SECRET_KEY_BASE` — any random string (`openssl rand -base64 48`).

Everything else has a sensible default:

- `OFFLOADER_CACHE_DIR` (default `/var/lib/offloader/cache`), `OFFLOADER_API_PORT` (4000),
  `OFFLOADER_ADMIN_PORT` (4001), `OFFLOADER_LOG_LEVEL` (info).
- `OFFLOADER_ADMIN_TOKEN` — recommended: gates the `/diagnostics` route (unset ⇒ it fails closed).
- `OFFLOADER_CONFIG_SYNC_INTERVAL` — seconds between bucket config re-checks (unset ⇒ off).
- `OFFLOADER_CORS_ORIGINS` — allow a browser front-end to call the API cross-origin: `*` or a
  comma-separated origin list (unset ⇒ no CORS). See [serving public data](public-serving.md).
- Tuning: `OFFLOADER_POOL_SIZE` (DuckDB read connections, default 16),
  `OFFLOADER_DUCKDB_THREADS` / `OFFLOADER_DUCKDB_MEMORY_LIMIT` (bound DuckDB to the container's
  memory allocation), `OFFLOADER_CACHE_MAX_ENTRIES` (response-cache entry ceiling, default
  10,000 — raise it for more distinct query shapes, lower it to cap cache memory).

Object-store credentials are needed only when your config reads from a remote source (below);
the local example needs no cloud vars and makes no outbound calls.

Source-specific object-store credentials are configured only when the mounted
config references that source. Offloader should not require cloud-provider env
vars or outbound telemetry for the local golden path.

### Remote snapshot credentials (optional)

A manifest whose `files[].path` is an `s3://`, `gs://`, or `https://` URL is read
directly by DuckDB (httpfs). Two credential modes:

- **S3-compatible / GCS HMAC** — `OFFLOADER_S3_TYPE=s3|gcs` plus
  `OFFLOADER_S3_KEY_ID`, `OFFLOADER_S3_SECRET` (and for S3: `OFFLOADER_S3_REGION`,
  `OFFLOADER_S3_ENDPOINT`, `OFFLOADER_S3_URL_STYLE`, `OFFLOADER_S3_SESSION_TOKEN`,
  `OFFLOADER_S3_USE_SSL`). Covers `s3://` and `gs://` paths.
- **GCS OAuth bearer** — `OFFLOADER_GCS_AUTH=bearer`. Tokens come from, in order:
  `OFFLOADER_GCS_TOKEN` (explicit), the GCE metadata server (the GKE/GCE production
  path), or the `gcloud` CLI (developer laptops). The token is registered as a
  DuckDB HTTP secret covering `https://storage.googleapis.com/...` reads and is
  rotated automatically before expiry. The Databricks GCS source
  (`Offloader.Source.Databricks`) uses the same tokens for listings and commit reads.

Explicit HMAC credentials win when both are set. Credentials never appear in logs,
error bodies, or support bundles (values are scrubbed; bundles are redacted).

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

## Config from object storage (optional)

`OFFLOADER_CONFIG` may be a **`gs://bucket/prefix/` URL** instead of a mounted path. At boot
Offloader fetches the whole project tree (`offloader.yml`, `datasets/`, `endpoints/`, the keys
file) from GCS into `<cache_dir>/config/` and loads it from there — so the container is fully
stateless: env vars in, config and data both in the bucket, nothing mounted.

- Uses the **GCS bearer token chain** (the same one the Databricks source lists with):
  `OFFLOADER_GCS_TOKEN`, the GCE metadata server, or `gcloud` — set `OFFLOADER_GCS_AUTH=bearer`.
  Remote config is GCS-only for now (`s3://`/`https://` config is not yet supported).
- Only `.yml`/`.yaml` objects under the prefix are fetched (bounded to 500 files / 32 MiB). A
  transient GCS error at boot is retried a few times; an invalid config fails boot loudly, exactly
  as a bad mounted config does.
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

## Useful helper commands

- `offloader init` — scaffold a new, valid project
- `offloader scaffold-dataset` — draft a dataset schema from a manifest or CSV
- `offloader validate`
- `offloader manifest validate`
- `offloader import-schema`
- `offloader shadow-diff`
- `offloader endpoint test`
- `offloader snapshot status`
- `offloader keys create`
- `offloader doctor`
- `offloader support-bundle`

### Importing an existing serving schema

If you already run a warehouse-backed serving API described by a `serving_schema.json`,
`offloader import-schema` generates a whole Offloader project from it: one dataset per
source table, one endpoint per query, with the source's `defaults`/`combinations`/
`param_aliases` preserved, plus a `mapping.json` the cutover diff harness uses. (In that
schema format each query is grouped by its `game` and `table` fields — hence the
`game__table` keys below; those are the schema's own field names, whatever your domain.)

Column types aren't in the schema file (its queries are `SELECT *`), so supply a hints
file — one DESCRIBE per table, mapping nested `STRUCT`/`MAP`/`LIST` columns to `JSON`:

```bash
# one row per source table: {"game__table": [{"name":"c","type":"VARCHAR"}, ...]}
offloader import-schema \
  --from serving_schema.json --hints schema_hints.json \
  --out ./project --bucket your-snapshot-bucket
```

Queries whose params aren't columns of their table (or whose table has no hints) fail
the run so nothing is silently mis-served; `--skip-broken` converts the rest and reports
each skip. The output passes `offloader validate` and serves live once GCS credentials
are set (see below).

## Config layout

The project directory `OFFLOADER_CONFIG` points at:

```text
offloader.yml       # top-level project file (version, dirs, auth mode, keys path)
datasets/           # one *.yml per dataset (the table contract)
endpoints/          # one *.yml per endpoint (the REST contract)
keys/keys.yml       # API keys, as hashes — omit for a public (auth: none) API
```

`offloader validate` checks the whole tree the same way the container does — run it in CI
before you ship a change. See `examples/customer-analytics/` for a complete, working project.
