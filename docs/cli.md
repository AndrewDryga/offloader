# CLI reference — the `offloader` helper

`offloader` is an **optional** command-line helper for authoring and operating a deployment. It
is **not** part of the container — the server needs only its config files and env vars — so you
install it only for the scaffolding, validation, and diagnostics commands below.

## Install

```sh
curl -fsSL https://offloader.dryga.com/install.sh | sh
```

Re-run any time to update. No installer (or you'd rather build it)? From a clone:

```sh
cd tools && go build -o offloader .   # then ./offloader <command>
```

The convention is `offloader <command> [flags]`, and every command takes `--help`.

## Author a project

### `offloader init`

Scaffold a complete, valid, fully-commented starter project (`offloader.yml` plus one dataset,
endpoint, and demo key).

| Flag | Default | Meaning |
| --- | --- | --- |
| `--out` | `offloader-project` | directory to create the project in |
| `--public` | off | scaffold a public project (`auth: none` — no keys, no tenant) |
| `--force` | off | overwrite existing files |

```sh
offloader init --out my-project
```

### `offloader scaffold-dataset`

Draft a `datasets/*.yml` schema from something you already have — reuse a manifest's schema, or
infer column types from a CSV.

| Flag | Meaning |
| --- | --- |
| `--from` | a `manifest.json` (reuse its schema) or a `.csv` (infer column types) |
| `--id` | dataset id (default: derived from the file/dir name) |
| `--tenant-column` | mark a column as the tenant column (multi-tenant datasets) |
| `--out` | write to this file (default: stdout) |

```sh
offloader scaffold-dataset --from data/events/manifest.json --tenant-column tenant_id
```

### `offloader validate`

Check a whole project the way the container does — every dataset, endpoint, and key. Run it in
CI before you ship a config change.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--config` | `offloader.yml` | path to the project's `offloader.yml` |

```sh
offloader validate --config my-project/offloader.yml
```

### `offloader manifest validate`

Validate one snapshot manifest file against its dataset contract.

```sh
offloader manifest validate my-project/data/events/manifest.json
```

## Run it

### `offloader serve`

Pull the published image and run it locally — the one-command POC path. Point it at a **local
project** (validated first, mounted read-only) **or a `gs://`/`s3://` config bucket** (served
directly via `OFFLOADER_CONFIG`, nothing mounted). A `gs://` bucket defaults to anonymous access,
so a public sample just works; set the `OFFLOADER_GCS_*`/`OFFLOADER_S3_*` credentials in your
environment for a private one and `serve` forwards them. Publishes the API on `:8088` and binds
the admin port to loopback, each bumped to the next free port if it's already taken.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--image` | `ghcr.io/andrewdryga/offloader:edge` | container image to run |
| `--api-port` | `8088` | host port for the product API (next free port if taken) |
| `--admin-port` | `8089` | host port for the admin surface (loopback; next free port if taken) |
| `--cache-volume` | `offloader-poc-cache` | Docker volume for the materialization cache |
| `--no-pull` | off | skip `docker pull` and use the local image as-is |

```sh
offloader serve my-project/
offloader serve gs://offloader-public-samples/offloader/   # the public demo, no credentials
```

### `offloader keys create`

Mint an API key: prints the bearer token **once** and the SHA-256 hash to paste into `keys.yml`
(only the hash is ever stored).

| Flag | Default | Meaning |
| --- | --- | --- |
| `--id` | `key1` | key id (a label; appears in diagnostics, never the token) |
| `--tenant` | `TENANT` | the tenant this key is bound to |
| `--endpoints` | — | comma-separated endpoint allowlist |

```sh
offloader keys create --id acme_prod --tenant tenant_acme --endpoints customer_usage_summary
```

## Verify and operate

### `offloader doctor`

Pre-flight check: the toolchain (`docker`, `curl`), optionally a project config, and optionally a
running server's admin `/ready`.

| Flag | Meaning |
| --- | --- |
| `--config` | validate this project config (optional) |
| `--admin-url` | ping this server admin URL (optional) |
| `--admin-token` | admin token for the server ping |

### `offloader endpoint test`

Call one endpoint on a running instance and assert its response status — a smoke test for CI or a
post-deploy check.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--url` | `http://localhost:4000` | server API base URL |
| `--endpoint` | — | endpoint name |
| `--key` | — | bearer API key |
| `--params` | — | query string, e.g. `from=2026-05-30&to=2026-06-01` |
| `--expect-status` | `200` | expected HTTP status |

### `offloader snapshot status`

Print a per-dataset summary from a running server: active / last-good snapshot, freshness, and
source health.

| Flag | Meaning |
| --- | --- |
| `--admin-url` | server admin base URL |
| `--admin-token` | admin token |

### `offloader docs`

Print (or open) the admin-port docs URLs — the generated endpoint catalog and OpenAPI spec.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--admin-url` | `http://localhost:4001` | server admin base URL |
| `--open` | off | open the endpoint catalog in a browser |

### `offloader support-bundle`

Collect a **redacted** config + diagnostics bundle into a tar.gz for support — secrets, tokens,
and credentialed URIs are masked; safe key hashes are kept.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--config` | `offloader.yml` | path to the project's `offloader.yml` |
| `--admin-url` | — | admin base URL to include redacted `/diagnostics` (optional) |
| `--admin-token` | — | admin token for `/diagnostics` |
| `--out` | `offloader-support-bundle.tar.gz` | output tar.gz path |

## Version

### `offloader version`

Print the helper version.
