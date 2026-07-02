# Offloader

Warehouse offload for production analytics APIs.

Offloader is a self-hostable container that moves repeated product-facing
analytical reads off Databricks, Snowflake, BigQuery, and similar warehouse
compute by serving approved object-storage snapshots through governed REST
contracts on infrastructure the customer already operates.

Status: **V1 planning / pre-pilot scaffold**. The first sellable offer is a
paid diagnostic plus offload pilot, not a broad data platform.

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

## V1 promise

For one production-facing dataset family, after prerequisites are ready:

- Serve 3-5 named analytical endpoints.
- Read approved Parquet snapshot manifests from object storage.
- Enforce API keys, endpoint allowlists, tenant filters, and column allowlists.
- Expose generated endpoint docs on the admin port.
- Preserve previous good snapshots on refresh failure.
- Report latency, freshness, request volume, and reducible warehouse spend.

## Repository layout

The layout follows the same language-rooted style as `../emisar`, but keeps
deployment customer-run and container-first.

```text
gateway/          Elixir/Phoenix self-hostable container: REST APIs, auth,
                  tenant enforcement, env-driven config, manifest refresh,
                  DuckDB materialization, admin/metrics port
tools/            Optional helper tooling: diagnostics, config validation,
                  manifest validation, endpoint tests, support bundles
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
