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
- `OFFLOADER_OBJECT_STORE_MODE`

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

## Useful helper commands

- `offloader validate`
- `offloader manifest validate`
- `offloader endpoint test`
- `offloader snapshot status`
- `offloader keys create`
- `offloader diff`
- `offloader doctor`
- `offloader support-bundle`

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
