# Offloader

[![CI](https://github.com/andrewdryga/offloader/actions/workflows/ci.yml/badge.svg)](https://github.com/andrewdryga/offloader/actions/workflows/ci.yml)

The serving layer for customer-facing analytics.

**In plain terms:** your product's dashboards and stats pages run queries against an
expensive data warehouse (Snowflake, Databricks, BigQuery) on every page load.
Offloader serves those same reads from cheap, pre-computed snapshots on your own
servers instead — cutting warehouse cost and speeding up responses. New to the idea?
Start with **[What Offloader is, in plain language](docs/concepts.md)**.

Offloader is a self-hostable container that moves repeated product-facing analytical
reads off Databricks, Snowflake, BigQuery, and similar warehouses by serving approved
object-storage snapshots through governed REST endpoints — on infrastructure you
already operate. There is no Offloader cloud, and your private data never leaves your
environment. (An optional managed CDN edge can serve already-public data — public only,
opt-in; see [serving public data](docs/public-serving.md).)

Status: the V1 gateway is **feature-complete and validated against real production
data**. The commercial offer is a paid diagnostic plus offload pilot, not a broad data
platform.

## Documentation

**New here → [What Offloader is, in plain language](docs/concepts.md)** (the words and
the mental model, no jargon).

Then, by what you want to do:

- **Try it** — [Quickstart](docs/quickstart.md): run it against a bundled example in ~15 minutes, no cloud needed.
- **Define your endpoints** — [Config guide](docs/developer-experience.md): what the `offloader.yml` + `datasets/`/`endpoints/`/`keys/` files look like.
- **Run it in production** — [Operator guide](docs/operator.md) · [Deployment](docs/deployment.md).
- **Security** — [Security model](docs/security-model.md): what's protected, and what you own.
- **Replace an existing serving API** — [Cutover runbook](docs/cutover-runbook.md): the safe, gradual switch-over.
- **Cost case** — [ROI diagnostic](docs/roi.md) · [Benchmarks](docs/benchmarks.md).


## Product boundary

Offloader is:

- A self-hostable serving container for bounded production analytics
  endpoints.
- A manifest-backed snapshot materializer and query runtime.
- A contract registry for REST APIs over approved serving datasets.
- A freshness, observability, and finance-grade ROI reporting layer.
- A two-port service: one API port for product traffic, one admin/metrics port
  for customer-owned observability and access controls.

Offloader is not:

- A warehouse replacement.
- A BI tool.
- A general SQL workspace.
- A streaming database.
- An ELT/data modeling tool.
- A hosted cloud service.
- A control plane, RBAC system, or SSO provider.

## What it does

The engineer's-eye view (the plain-language version is in [concepts](docs/concepts.md)):

- Serve named, versioned REST endpoints over approved Parquet/CSV snapshots,
  materialized into DuckDB and swapped in atomically.
- Read snapshots from the **local filesystem OR remote object storage** — `s3://`,
  `gs://`, `https://` via DuckDB httpfs, with S3/GCS-HMAC or GCS-OAuth-bearer
  credentials from env (never a request).
- Boot **fully stateless**: point `OFFLOADER_CONFIG` at a `gs://…` prefix and the whole
  project (datasets, endpoints, keys) is fetched from the bucket at startup — config and
  data in the same place, nothing mounted. With `OFFLOADER_CONFIG_SYNC_INTERVAL` it also
  **hot-reloads** bucket changes with **zero downtime**, blue-green even across a schema change.
- Follow a producer that publishes on its own schedule: a **Databricks
  commit-protocol resolver** discovers the latest `_committed_<tid>` in GCS and
  refreshes per-dataset, isolated so one slow/broken source never blocks the rest;
  warm-start serves the on-disk snapshot instantly on restart.
- Enforce API keys, endpoint allowlists, compiler-inserted tenant filters, and column
  allowlists — **or** run fully public (`auth: none`, accepted only when no endpoint
  is tenant-scoped).
- Serve nested `STRUCT`/`MAP`/`LIST` columns as native JSON, and the same query
  ergonomics: `combinations`, per-param value `aliases`, applied `defaults`, and an
  allowlist-bounded `?columns=` subset.
- Scale: a DuckDB read-connection pool + per-request serving in the caller process
  (~5–6k req/s cached, p99 < 60ms on 50KB nested payloads; validated at 66
  datasets / 67 endpoints against a real GCS bucket — see `docs/benchmarks.md`).
- Expose generated docs/OpenAPI + a client `/schema`, Prometheus metrics (pool,
  refresh, per-endpoint latency), and redacted diagnostics on a separate admin port.
- Preserve the previous good snapshot on refresh failure (`rollback`), and ship a
  signed container image via CI on every version tag.

## Replacing an existing serving API

Offloader was built and proven to replace a real warehouse-backed serving API's production serving:
`offloader import-schema` converts a `serving_schema.json` into a whole project, and
`offloader shadow-diff` gates the cutover on proven response parity against the live
system. See **[the cutover runbook](docs/cutover-runbook.md)** for the shadow → canary → cutover playbook.

## Runtime configuration

The primary product surface is the container plus environment variables. A standard
deployment needs only:

```sh
docker run \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_CACHE_DIR=/var/lib/offloader/cache \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v ./offloader.yml:/etc/offloader/offloader.yml:ro \
  -v offloader-cache:/var/lib/offloader/cache \
  -p 4000:4000 \
  -p 127.0.0.1:4001:4001 \
  ghcr.io/andrewdryga/offloader:<version>
```

The full env-var reference is in the [config guide](docs/developer-experience.md).

## Repository layout

```text
gateway/          Elixir/Phoenix self-hostable container: REST APIs, auth,
                  tenant enforcement, env-driven config, manifest refresh,
                  DuckDB materialization, admin/metrics port
tools/            Optional helper CLI: config/manifest validation, serving-schema
                  import (import-schema), cutover response-diff (shadow-diff),
                  diagnostics, endpoint tests, support bundles
deploy/           Container deployment notes and examples; no managed cloud scaffold
docs/             Product, architecture, security, operations, and release docs
examples/         Local demo manifests, endpoint configs, and sample datasets
dev/              Local verification, benchmark, and deployment-check scripts
```

## Project status (for contributors)

(technical + commercial proof gates). The development gate is:

```sh
make check        # format, warnings-as-errors, tests
make e2e          # manifest -> HTTP smoke
make deploy-check # build the prod image, boot it, verify both ports
```
