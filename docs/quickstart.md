# Quickstart — serve a real endpoint in 15 minutes

Run Offloader with sample data, call a REST endpoint, and check that it rejects an
invalid request. You need Docker, Git, and about 15 minutes. No cloud account is
required. The docs examples also use `curl` and `jq`.

New to the product? Start with [How Offloader works](concepts.md).

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
docker build -t offloader:dev -f server/Dockerfile server
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

Leave the container running. Open another terminal and check that it is ready.
The admin readiness check returns 200 once Offloader has loaded the snapshot;
until then, it returns 503:

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
  "data": [ { "account_id": "acct_zephyr", "active_users_total": 244, "api_calls_total": 56839, "storage_gb_avg": 34.300000000000004 }, "…" ],
  "meta": {
    "request_id": "…", "endpoint": "customer_usage_summary", "version": 1,
    "snapshot_id": "2026-06-01T00:00:00Z_r0007", "generated_at": "2026-07-01T18:21:10Z", "row_count": 2,
    "serving_mode": "local_table", "cache": "miss",
    "freshness": { "watermark": "2026-06-01T00:00:00Z", "age_seconds": 2658070, "max_staleness_minutes": 120, "stale": true }
  }
}
```

Each successful data response includes its `snapshot_id` and freshness. Here,
`stale: true` means the demo data is older than its 120-minute limit. Offloader
still serves it; your app decides whether the age is acceptable.

## 3. Read the generated docs

The endpoint catalog and OpenAPI spec are generated from your endpoint definitions and served on
the **admin** port (never the API port):

```sh
curl -s http://127.0.0.1:4001/docs | jq '.endpoints[].name'
curl -s http://127.0.0.1:4001/openapi.json | jq '.paths | keys'
```

These docs list each endpoint's parameters, defaults, limits, response fields, and
errors, with curl, TypeScript, and Python examples.

## 4. Try a request the endpoint rejects

This endpoint rejects undeclared parameters. Try adding a tenant ID: the request
returns `422 invalid_param`.

```sh
# an unknown/undeclared param (e.g. smuggling a tenant) -> 422 invalid_param
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer offl_demo_acme_key" \
  "http://localhost:4000/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01&tenant_id=tenant_globex"
# 422
```

The [failure lab](../examples/customer-analytics/failure-lab/README.md) has the full set (bad
manifest, stale dataset, forbidden tenant, …) and the exact error each returns.

## 5. Start your own project

To serve **your** data, create a project with the
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

These two configuration files define the dataset and endpoint. This example is
shortened from what `init` generated:

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

The CLI starts the API on port **8088** and admin pages on **8089**, or the next
free ports. Use the URLs it prints; these differ from the Docker example above. The
[config guide](developer-experience.md) walks through every file; the
[config reference](config-reference.md) lists every field.

<details>
<summary>Let an AI agent migrate your existing endpoints</summary>

Already have analytics endpoints (raw SQL, an ORM, a hand-rolled API)? Point a coding agent at
both your code and this repo, and paste:

> You are migrating our existing analytics endpoints to Offloader. Read Offloader's
> `docs/config-reference.md` and the `examples/customer-analytics/` project for the exact schema.
> For **each** of our current endpoints: (1) write a `datasets/<id>.yml` whose `schema` matches
> the exported Parquet columns, including tenant and filter columns; (2) write an `endpoints/<name>.yml` reproducing its params, filters,
> aggregation, ordering, and limits using only Offloader's declarative `query:` — no raw SQL;
> (3) preserve tenant isolation by setting the dataset's `tenant_column` and the endpoint's
> `tenant:`. Then run `offloader validate --config my-project/offloader.yml` and
> `offloader endpoint test` against a running instance, and fix every reported error until both
> pass. Finally, list any endpoint you could not express and exactly why.

It produces a project you own and can diff — review it before serving.
</details>

## 6. Next

- [Config guide](developer-experience.md) — publish your own datasets and endpoints, and load
  config from a `gs://`/`s3://` bucket. Apply supported updates without restarting.
- [Operator guide](operator.md) · [Deployment](deployment.md) — run it in production: size,
  upgrade, roll back, diagnose.
- Hand the generated endpoint docs (step 3) to a product engineer to integrate against.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Container exits immediately | Missing `OFFLOADER_SECRET_KEY_BASE`, or `OFFLOADER_CONFIG` not mounted. |
| `/ready` stays 503 | Offloader has not loaded the snapshot. Check the logs in the terminal running Docker; see the [operator guide](operator.md) for diagnostics. |
| Endpoint returns 401 | Missing/invalid/revoked key. Mint one with `offloader keys create`. |
| Endpoint returns 404 | Unknown endpoint, or the key isn't granted it (indistinguishable, on purpose). |
| Endpoint returns 422 | A param is missing/mistyped/out of range, or an undeclared param was sent. |
