# Developer Experience Contract

V1 must feel like running a production-ready self-hosted container, not learning
a bespoke CLI. Tooling is welcome, but the happy path starts with env vars,
mounted config, and a health check.

## First-hour golden path

```sh
cp examples/customer-analytics/offloader.yml ./offloader.yml
docker run --rm \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_CACHE_DIR=/var/lib/offloader/cache \
  -e OFFLOADER_API_PORT=4000 \
  -e OFFLOADER_ADMIN_PORT=4001 \
  -p 4000:4000 \
  -p 127.0.0.1:4001:4001 \
  -v "$PWD/offloader.yml:/etc/offloader/offloader.yml:ro" \
  -v offloader-cache:/var/lib/offloader/cache \
  ghcr.io/<owner>/offloader:dev
curl -H "Authorization: Bearer $OFFLOADER_DEMO_KEY" \
  http://localhost:4000/v1/endpoints/customer_usage_summary
```

Acceptance:

- A buyer sees a running container, working endpoint, docs, manifest, config,
  metrics, and one failure example in under 15 minutes locally.
- A data engineer can publish the first endpoint by mounting config and a local
  Parquet manifest, then move the same config to S3/GCS manifests.
- A product engineer can integrate from generated docs without reading operator
  docs.

## Required container env vars

- `OFFLOADER_CONFIG`
- `OFFLOADER_CACHE_DIR`
- `OFFLOADER_API_PORT`
- `OFFLOADER_ADMIN_PORT`
- `OFFLOADER_SECRET_KEY_BASE`
- `OFFLOADER_LOG_LEVEL`

Tuning (optional): `OFFLOADER_POOL_SIZE` (DuckDB read connections, default 16),
`OFFLOADER_DUCKDB_THREADS` / `OFFLOADER_DUCKDB_MEMORY_LIMIT` (bound DuckDB to the
container's cgroup allocation).

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

- `offloader validate`
- `offloader manifest validate`
- `offloader import-schema`
- `offloader shadow-diff`
- `offloader endpoint test`
- `offloader snapshot status`
- `offloader keys create`
- `offloader diff`
- `offloader doctor`
- `offloader support-bundle`

### Importing an existing serving schema

`offloader import-schema` generates a whole Offloader project from a
`serving_schema.json` (one dataset per `{game,table}` as a Databricks GCS source, one
endpoint per query, the source `defaults`/`combinations`/`param_aliases` preserved, plus a
`mapping.json` for the cutover diff harness). Column types are not in the schema file
(the source is `SELECT *`), so supply a hints file — one DESCRIBE per table, mapping
nested `STRUCT`/`MAP`/`LIST` columns to `JSON`:

```bash
# one row per {game,table}: {"game__table": [{"name":"c","type":"VARCHAR"}, ...]}
offloader import-schema \
  --from serving_schema.json --hints schema_hints.json \
  --out ./project --bucket databricks-serving-databases
```

Queries whose params aren't columns of their table (or whose table has no hints) fail
the run so nothing is silently mis-served; `--skip-broken` converts the rest and reports
each skip. The output passes `offloader validate` and serves live once GCS credentials
are set (see below).

## Config layout

```text
offloader/
  offloader.yml
  sources/
  datasets/
  endpoints/
  policies/
  keys/
  examples/
  tests/
```

Every config file gets JSON Schema, versioning, examples, and CI validation.
