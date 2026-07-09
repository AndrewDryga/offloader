# Offloader

[![CI](https://github.com/andrewdryga/offloader/actions/workflows/ci.yml/badge.svg)](https://github.com/andrewdryga/offloader/actions/workflows/ci.yml)

Self-hosted REST endpoints for product data your warehouse produces.

**In plain terms:** your warehouse computes data your product needs — usage meters,
billing totals, leaderboards, recommendations, customer analytics. If your backend
calls Snowflake, Databricks, BigQuery, or similar systems every time a user waits for
that data, you pay warehouse cost and latency on every request.

Offloader lets your pipeline publish that data as snapshots, then serves named REST
endpoints from those snapshots on your own servers. The warehouse builds the data
once; your app reads it cheaply until the next snapshot is ready. New to the idea?
Start with **[What Offloader is, in plain language](https://offloader.dryga.com/docs/concepts.html)**.

Offloader is a container you run. It reads approved Parquet/CSV snapshots from object
storage, loads them into DuckDB, and exposes only the REST endpoints you configure.
There is no Offloader cloud, and private data stays in your environment by default.
An optional managed CDN edge can serve already-public data only; see
[serving public data](https://offloader.dryga.com/docs/public-serving.html).

Status: the server is **feature-complete and validated against real production
data**. The commercial offer is a paid diagnostic plus offload pilot, not a broad data
platform.

## Documentation

**New here → [What Offloader is, in plain language](https://offloader.dryga.com/docs/concepts.html)** (the words and
the mental model, no jargon).

Then, by what you want to do:

- **Try it** — [Quickstart](https://offloader.dryga.com/docs/quickstart.html): run it against a bundled example in ~15 minutes, no cloud needed.
- **Define your endpoints** — [Config guide](https://offloader.dryga.com/docs/developer-experience.html): what the `offloader.yml` + `datasets/`/`endpoints/`/`keys/` files look like.
- **Tooling** — [CLI reference](https://offloader.dryga.com/docs/cli.html): the optional `offloader` helper, every command and flag.
- **Run it in production** — [Operator guide](https://offloader.dryga.com/docs/operator.html) · [Deployment](https://offloader.dryga.com/docs/deployment.html).
- **Security** — [Security model](https://offloader.dryga.com/docs/security-model.html): what's protected, and what you own.
- **Cost case** — [ROI calculator](https://offloader.dryga.com/roi.html) · [Benchmarks](https://offloader.dryga.com/docs/benchmarks.html).

Deeper: [Architecture](docs/architecture.md) · [Release process](docs/release.md).

## Product boundary

Offloader is:

- A container you run for named, read-only product API endpoints over warehouse
  snapshots.
- A snapshot loader: it follows manifests, validates files and schema, and loads
  the active snapshot into DuckDB.
- A REST endpoint registry: URLs, params, API keys, tenants, and allowed columns live
  in config.
- Freshness, metrics, diagnostics, and before/after ROI reporting.
- A two-port service: one API port for product traffic, one admin/metrics port
  for customer-owned observability and access controls.

Offloader is not:

- A warehouse replacement.
- A BI tool.
- A dashboard refresh layer for internal BI.
- A general SQL workspace.
- A streaming database.
- An ELT/data modeling tool.
- A hosted cloud service.
- A control plane, RBAC system, or SSO provider.

## What it replaces

Offloader is for the read path teams usually build by hand after product API traffic
starts hitting warehouse-backed data:

- Product endpoints that query Snowflake, Databricks, BigQuery, or similar systems
  while a customer waits.
- Homegrown Redis/Postgres/DuckDB cache services without snapshot validation,
  rollback, generated docs, diagnostics, or safe swaps.
- A second serving database when the workload is read-only, fresh enough from
  snapshots, and a REST API is all your app needs.
- Tenant filters, endpoint allowlists, and column limits scattered across app
  handlers instead of enforced in one place.

## What it does

The engineer's-eye view (the plain-language version is in [concepts](https://offloader.dryga.com/docs/concepts.html)):

- Serve named, versioned REST endpoints over approved Parquet/CSV snapshots,
  materialized into DuckDB and swapped in atomically.
- Read snapshots from the **local filesystem OR remote object storage** — `s3://`,
  `gs://`, `https://` via DuckDB httpfs, with S3/GCS-HMAC or GCS-OAuth-bearer
  credentials from env (never a request).
- Boot **fully stateless**: point `OFFLOADER_CONFIG` at a `gs://…` prefix and the whole
  project (datasets, endpoints, keys) is fetched from the bucket at startup — config and
  data in the same place, nothing mounted. With `OFFLOADER_CONFIG_SYNC_INTERVAL` it also
  **hot-reloads** bucket changes with **zero downtime**, blue-green even across a schema change.
- Follow a producer that publishes on its own schedule: the Databricks
  commit-protocol resolver discovers the latest `_committed_<tid>` in GCS and
  refreshes per dataset. One slow or broken source does not block the rest; a
  warm restart serves the on-disk snapshot right away.
- Enforce API keys, endpoint allowlists, compiler-inserted tenant filters, and column
  allowlists — **or** run fully public (`auth: none`, accepted only when no endpoint
  is tenant-scoped).
- Serve nested `STRUCT`/`MAP`/`LIST` columns as native JSON, and the same query
  ergonomics: `combinations`, per-param value `aliases`, applied `defaults`, and an
  allowlist-bounded `?columns=` subset.
- Scale: a DuckDB read-connection pool + per-request serving in the caller process
  (~5–6k req/s cached, p99 < 60ms on 50KB nested payloads; validated at 66
  datasets / 67 endpoints against a real production GCS bucket). Measure on your own
  data with the [benchmark harness](https://offloader.dryga.com/docs/benchmarks.html).
- Expose generated docs/OpenAPI + a client `/schema`, Prometheus metrics (pool,
  refresh, per-endpoint latency), and redacted diagnostics on a separate admin port.
- Preserve the previous good snapshot on refresh failure (`rollback`), and ship a
  signed container image via CI on every version tag.

## Runtime configuration

The primary product surface is the container plus environment variables. A standard
deployment needs only:

```sh
docker run \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_CACHE_DIR=/var/lib/offloader/cache \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v ./my-project:/etc/offloader:ro \
  -v offloader-cache:/var/lib/offloader/cache \
  -p 4000:4000 \
  -p 127.0.0.1:4001:4001 \
  ghcr.io/andrewdryga/offloader:<version>
```

The full env-var reference is in the [config guide](https://offloader.dryga.com/docs/developer-experience.html).

## Repository layout

```text
server/          Elixir/Phoenix self-hostable container: REST APIs, auth,
                  tenant enforcement, env-driven config, manifest refresh,
                  DuckDB materialization, admin/metrics port
tools/            Optional helper CLI (docs/cli.md): project scaffolding, config/
                  manifest validation, local serve for POCs, key minting,
                  diagnostics, endpoint tests, support bundles, ROI report
deploy/           Container deployment notes and examples; no managed cloud scaffold
docs/             Product, architecture, security, operations, and release docs
examples/         Local demo manifests, endpoint configs, and sample datasets
dev/              Local verification, benchmark, and deployment-check scripts
legal/            Contracting templates (diagnostic + pilot SOW) — fill per deal
```

## Project status (for contributors)

The development gate is:

```sh
make check        # format, warnings-as-errors, tests
make e2e          # manifest -> HTTP smoke
make deploy-check # build the prod image, boot it, verify both ports
```

## License

Offloader is source-available under the **[Business Source License 1.1](LICENSE)** (BSL 1.1).
In plain terms: you may read, modify, redistribute, and self-host it, and **run it in production
free of charge if your organization's total annual revenue is under $1M**. At or above $1M,
production use needs a commercial license (that's the paid engagement). Every release
**automatically converts to Apache-2.0 two years after it ships**, so each version becomes fully
open-source on a clock — and either way there's **no lock-in**: you keep your container, your
data, and the full source.
