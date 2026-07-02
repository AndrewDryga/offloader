# Offloader

[![CI](https://github.com/andrewdryga/offloader/actions/workflows/ci.yml/badge.svg)](https://github.com/andrewdryga/offloader/actions/workflows/ci.yml)

Warehouse offload for production analytics APIs.

Offloader is a self-hostable container that moves repeated product-facing
analytical reads off Databricks, Snowflake, BigQuery, and similar warehouse
compute by serving approved object-storage snapshots through governed REST
contracts on infrastructure the customer already operates.

Status: the V1 gateway is **feature-complete and validated against real production
data** (see the `upstream_serving_api` replacement below). The commercial offer is a paid
diagnostic plus offload pilot, not a broad data platform.

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

- Serve named, versioned REST endpoints over approved Parquet/CSV snapshots,
  materialized into DuckDB and swapped in atomically.
- Read snapshots from the **local filesystem OR remote object storage** — `s3://`,
  `gs://`, `https://` via DuckDB httpfs, with S3/GCS-HMAC or GCS-OAuth-bearer
  credentials from env (never a request).
- Follow a producer that publishes on its own schedule: a **Databricks
  commit-protocol resolver** discovers the latest `_committed_<tid>` in GCS and
  refreshes per-dataset, isolated so one slow/broken source never blocks the rest;
  warm-start serves the on-disk snapshot instantly on restart.
- Enforce API keys, endpoint allowlists, compiler-inserted tenant filters, and column
  allowlists — **or** run fully public (`auth: none`, accepted only when no endpoint
  is tenant-scoped).
- Serve nested `STRUCT`/`MAP`/`LIST` columns as native JSON, and upstream-style query
  ergonomics: `combinations`, per-param value `aliases`, applied `defaults`, and an
  allowlist-bounded `?columns=` subset.
- Scale: a DuckDB read-connection pool + per-request serving in the caller process
  (~5–6k req/s cached, p99 < 60ms on 50KB nested payloads; validated at 66
  datasets / 67 endpoints against a real GCS bucket — see `docs/benchmarks.md`).
- Expose generated docs/OpenAPI + a client `/schema`, Prometheus metrics (pool,
  refresh, per-endpoint latency), and redacted diagnostics on a separate admin port.
- Preserve the previous good snapshot on refresh failure (`rollback`), and ship a
  signed container image via CI on every version tag.

## Replacing an existing serving API (upstream_serving_api)

Offloader was built and proven to replace `upstream_serving_api`'s production serving:
`offloader import-schema` converts a `serving_schema.json` into a whole project, and
`offloader shadow-diff` gates the cutover on proven response parity against the live
system. See **`docs/cutover-runbook.md`** for the shadow → canary → cutover playbook.

## Repository layout

The layout follows the same language-rooted style as `../emisar`, but keeps
deployment customer-run and container-first.

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

## First technical gate

Before promising an external deployment, prove:

1. One non-game dataset family.
2. Three generic endpoints.
3. Manifest to DuckDB materialization to HTTP response.
4. Docs/schema endpoints served on the admin port.
5. API-key auth and tenant enforcement.
6. Failed refresh keeps previous good snapshot.
7. Cold load, warm restart, memory, disk, p95, and p99 measurements.
8. Standalone container starts from empty and warm cache.

The authoritative, citeable version — every gate mapped to its owning task and
`Q01` audits the release against it.

## Development gate

The exact gate will harden as components land. The intended V1 gate is:

```sh
make check
make e2e
make deploy-check
```

Early tasks should add these targets as soon as the component skeletons exist.

## Runtime configuration

The primary V1 product surface is the container plus environment variables.
Helper tooling is useful, but a standard deployment must be possible with:

```sh
docker run \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_CACHE_DIR=/var/lib/offloader/cache \
  -e OFFLOADER_API_PORT=4000 \
  -e OFFLOADER_ADMIN_PORT=4001 \
  -v ./offloader.yml:/etc/offloader/offloader.yml:ro \
  -v offloader-cache:/var/lib/offloader/cache \
  -p 4000:4000 \
  -p 127.0.0.1:4001:4001 \
  ghcr.io/<owner>/offloader:<version>
```

## Planning

- [Quickstart — the first hour](docs/quickstart.md)
- [Operator guide](docs/operator.md)
- [Architecture](docs/architecture.md)
- [Deployment](docs/deployment.md)
- [Security model](docs/security-model.md)

Implementation work is queued with `coop tasks` under `.agent/tasks/`.
