# Quickstart — serve a real endpoint in 15 minutes

Pull the published image, run it against a ready-made example project (real sample data
included), call an endpoint, read the generated docs, and watch a bad request fail safely —
about fifteen minutes, no cloud required.

New to Offloader? Read [What Offloader is, in plain language](concepts.md) first (5 minutes) —
it defines the words used below.

## 0. Get the example and the image

You serve from a **project** — an `offloader.yml` plus its datasets, endpoints, keys, and a
snapshot. You can't just start the bare container; it needs a config and data to serve. The
repo ships a complete, working project (with sample data) in `examples/customer-analytics/`, so
clone it and pull the image:

```sh
git clone https://github.com/andrewdryga/offloader.git
cd offloader
docker pull ghcr.io/andrewdryga/offloader:edge   # rolling build of main; or pin a release tag
```

Nothing is baked into the image — the example project is **mounted from your clone** at run
time, which is exactly how you'll later mount your own project.

<details>
<summary>Prefer to build the image yourself?</summary>

```sh
docker build -t offloader:dev -f gateway/Dockerfile gateway
```

Then use `offloader:dev` in place of the `ghcr.io/…` image in every command below.
</details>

## 1. Run the container

Mount the example project read-only; secrets come from env vars; the admin port binds to
loopback:

```sh
docker run --rm \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e OFFLOADER_ADMIN_TOKEN="$(openssl rand -base64 24)" \
  -p 4000:4000 \
  -p 127.0.0.1:4001:4001 \
  -v "$PWD/examples/customer-analytics:/etc/offloader:ro" \
  -v offloader-cache:/var/lib/offloader/cache \
  ghcr.io/andrewdryga/offloader:edge
```

Wait until the admin **readiness** probe returns 200 (it stays 503 until the snapshot is
materialized):

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

Every response carries `snapshot_id` and freshness — you always know exactly which snapshot
you're reading. (`stale:true` here just means the demo data is older than its 120-minute
tolerance.)

## 3. Read the generated docs

The endpoint catalog and OpenAPI spec are generated from the enforced contracts and served on
the **admin** port (never the API port):

```sh
curl -s http://127.0.0.1:4001/docs | jq '.endpoints[].name'
curl -s http://127.0.0.1:4001/openapi.json | jq '.paths | keys'
```

A product engineer integrates from these — params, defaults, limits, response shape, error
families, and curl/TypeScript/Python snippets are all there.

## 4. See a failure fail safely

Bad input is rejected with a named error family — never a leak, never a 500:

```sh
# an unknown/undeclared param (e.g. smuggling a tenant) -> 422 invalid_param
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer offl_demo_acme_key" \
  "http://localhost:4000/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01&tenant_id=tenant_globex"
# 422
```

The [failure lab](../examples/customer-analytics/failure-lab/README.md) has the full set (bad
manifest, stale dataset, forbidden tenant, …) and what each must produce.

## 5. Start your own project

The bundled example proves the path; to serve **your** data, scaffold a fresh project with the
`offloader` CLI (an optional helper — not part of the container). Install or update it:

```sh
curl -fsSL https://offloader.dryga.com/install.sh | sh
```

<details>
<summary>No installer? build from source (needs Go)</summary>

```sh
cd tools && go build -o offloader .    # then ./offloader <command>
```
</details>

Scaffold a starter project and check it exactly the way the container does:

```sh
# a complete, valid, fully-commented project (one dataset + endpoint + demo key)
offloader init --out my-project

# validate the whole tree before you run anything
offloader validate --config my-project/offloader.yml
```

The two files you edit are small and declarative — no SQL. Abridged from what `init` just
generated:

```yaml
# my-project/datasets/events.yml — the table + the columns you serve
id: events
manifest: data/events/manifest.json   # point this at your snapshot (Parquet + a manifest.json)
tenant_column: tenant_id
schema:
  - { name: event_date,  type: DATE }
  - { name: tenant_id,   type: VARCHAR }
  - { name: account_id,  type: VARCHAR }
  - { name: event_count, type: BIGINT }
```

```yaml
# my-project/endpoints/events_by_day.yml — the REST contract over that dataset
name: events_by_day
version: 1
dataset: events
tenant: { column: tenant_id }
params:
  - { name: from, type: date, required: true }
  - { name: to,   type: date, required: true }
query:
  group_by: [account_id]
  select:
    - { as: account_id,        column: account_id }
    - { as: event_count_total, column: event_count, agg: sum }
  filters:
    - { column: event_date, op: gte, param: from }
    - { column: event_date, op: lte, param: to }
columns: [account_id, event_count_total]
```

Point `manifest:` at a snapshot of your data, then serve it locally in one command:

```sh
offloader serve my-project/   # validates the config, pulls the image, runs it against your project
```

That's the shortcut for the full `docker run` in step 1 — handy for a POC. The
[config guide](developer-experience.md) walks through every file; the
[config reference](config-reference.md) lists every field.

<details>
<summary>Let an AI agent migrate your existing endpoints</summary>

Already have analytics endpoints (raw SQL, an ORM, a hand-rolled API)? Point a coding agent at
both your code and this repo, and paste:

> You are migrating our existing analytics endpoints to Offloader. Read Offloader's
> `docs/config-reference.md` and the `examples/customer-analytics/` project for the exact schema.
> For **each** of our current endpoints: (1) write a `datasets/<id>.yml` whose `schema` matches
> the columns it returns; (2) write an `endpoints/<name>.yml` reproducing its params, filters,
> aggregation, ordering, and limits using only Offloader's declarative `query:` — no raw SQL;
> (3) preserve tenant isolation by setting the dataset's `tenant_column` and the endpoint's
> `tenant:`. Then run `offloader validate --config my-project/offloader.yml` and
> `offloader endpoint test` against a running instance, and fix every reported error until both
> pass. Finally, list any endpoint you could not express and exactly why.

It produces a project you own and can diff — review it before serving.
</details>

## 6. Next

- [Config guide](developer-experience.md) — publish your own datasets and endpoints, and load
  config from a `gs://`/`s3://` bucket (fully stateless, with zero-downtime hot-reload).
- [Operator guide](operator.md) · [Deployment](deployment.md) — run it in production: size,
  upgrade, roll back, diagnose.
- Hand the generated endpoint docs (step 3) to a product engineer to integrate against.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container exits immediately | Missing `OFFLOADER_SECRET_KEY_BASE`, or `OFFLOADER_CONFIG` not mounted. |
| `/ready` stays 503 | The snapshot hasn't materialized — check `docker logs` and admin `/diagnostics`. |
| Endpoint returns 401 | Missing/invalid/revoked key. Mint one with `offloader keys create`. |
| Endpoint returns 404 | Unknown endpoint, or the key isn't granted it (indistinguishable, on purpose). |
| Endpoint returns 422 | A param is missing/mistyped/out of range, or an undeclared param was sent. |
