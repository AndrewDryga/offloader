# Quickstart — run it in 15 minutes

Run Offloader as a container against the bundled example, call an endpoint, read the
generated docs, and see a failure fail safely — in about fifteen minutes, no cloud
required. Every command here is exercised by `make e2e` and `make deploy-check`.

New to the idea of Offloader? Read [What Offloader is, in plain language](concepts.md)
first (5 minutes) — it defines the words used below.

## 0. Prerequisites

Docker, and this repo (for the example config in `examples/customer-analytics/`).
A published image will be `ghcr.io/OWNER/offloader:<version>`; until then, build it:

```sh
docker build -t offloader:dev -f gateway/Dockerfile gateway
```

## 1. Run the container

The config directory (`offloader.yml` + `datasets/`, `endpoints/`, `keys/`, data) is
mounted; secrets come from env vars; the admin port is bound to loopback.

```sh
docker run --rm \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e OFFLOADER_ADMIN_TOKEN="$(openssl rand -base64 24)" \
  -p 4000:4000 \
  -p 127.0.0.1:4001:4001 \
  -v "$PWD/examples/customer-analytics:/etc/offloader:ro" \
  -v offloader-cache:/var/lib/offloader/cache \
  offloader:dev
```

Wait until the admin **readiness** probe returns 200 (it stays 503 until the snapshot
is materialized):

```sh
curl -fsS http://127.0.0.1:4001/ready
# {"status":"ok","ready":true}
```

## 2. Call your first endpoint

The example ships a demo key `offl_demo_acme_key` bound to `tenant_acme`:

```sh
curl -H "Authorization: Bearer offl_demo_acme_key" \
  "http://localhost:4000/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01"
```

```json
{
  "data": [ { "account_id": "acct_zephyr", "active_users_total": 244, "api_calls_total": 56839, "storage_gb_avg": 34.3 }, "…" ],
  "meta": {
    "request_id": "…", "endpoint": "customer_usage_summary",
    "snapshot_id": "2026-06-01T00:00:00Z_r0007", "row_count": 2,
    "serving_mode": "local_table", "cache": "miss",
    "freshness": { "watermark": "2026-06-01T00:00:00Z", "age_seconds": 2658070, "stale": true }
  }
}
```

Every response carries `snapshot_id` and freshness — you always know exactly which
snapshot you're reading. (`stale:true` here just means the demo data is older than its
120-minute tolerance.)

## 3. Read the generated docs

The endpoint catalog and OpenAPI spec are generated from the enforced contracts and
served on the **admin** port (never the API port):

```sh
curl -s http://127.0.0.1:4001/docs | jq '.endpoints[].name'
curl -s http://127.0.0.1:4001/openapi.json | jq '.paths | keys'
```

A product engineer integrates from these — params, defaults, limits, response shape,
error families, and curl/TypeScript/Python snippets are all there.

## 4. Validate config (optional helper)

`offloader` is an **optional Go helper** (not part of the container). Build it once, then it
checks config the same way the container does:

```sh
cd tools && go build -o offloader .   # produces ./offloader; or run inline with `go run . …`
```

```sh
offloader validate --config examples/customer-analytics/offloader.yml   # "config OK"
offloader manifest validate examples/customer-analytics/data/customer_usage/manifest.json
```

## 5. See a failure fail safely

Bad input is rejected with a named error family — never a leak, never a 500:

```sh
# an unknown/undeclared param (e.g. smuggling a tenant) -> 422 invalid_param
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer offl_demo_acme_key" \
  "http://localhost:4000/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01&tenant_id=tenant_globex"
# 422
```

The [failure lab](../examples/customer-analytics/failure-lab/README.md) has the full
set (bad manifest, stale dataset, forbidden tenant, …) and what each must produce.

## 6. Next

- [Config guide](developer-experience.md) — how to publish your own dataset + endpoint, and
  how to load config from a `gs://` bucket (fully stateless, with zero-downtime hot-reload).
- The generated endpoint docs (step 3) — hand these to a product engineer to integrate.
- [Operator guide](operator.md) · [Deployment](deployment.md) — run it in production: deploy,
  size, upgrade, roll back.
- [`make e2e`](../dev/scripts/e2e.sh) — the manifest→HTTP smoke this quickstart mirrors.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container exits immediately | Missing `OFFLOADER_SECRET_KEY_BASE`, or `OFFLOADER_CONFIG` not mounted. |
| `/ready` stays 503 | The snapshot hasn't materialized — check `docker logs` and admin `/diagnostics`. |
| Endpoint returns 401 | Missing/invalid/revoked key. Mint one with `offloader keys create`. |
| Endpoint returns 404 | Unknown endpoint, or the key isn't granted it (indistinguishable, on purpose). |
| Endpoint returns 422 | A param is missing/mistyped/out of range, or an undeclared param was sent. |
