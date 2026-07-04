# Single-node `docker run`

The smallest way to run Offloader: one container, a mounted config directory, a
cache volume, and env-var secrets.

```sh
docker run --rm \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e OFFLOADER_ADMIN_TOKEN="$(openssl rand -base64 24)" \
  -e OFFLOADER_LOG_LEVEL=info \
  -p 4000:4000 \
  -p 127.0.0.1:4001:4001 \
  -v "$PWD/offloader:/etc/offloader:ro" \
  -v offloader-cache:/var/lib/offloader/cache \
  ghcr.io/andrewdryga/offloader:0.1.1        # pin a version — never :latest
```

## What each part does

| Flag | Why |
| --- | --- |
| `-e OFFLOADER_CONFIG` | Path to the mounted `offloader.yml` (see `examples/customer-analytics/`). |
| `-e OFFLOADER_SECRET_KEY_BASE` | Required in prod; the container refuses to boot without it. Keep it in your secret store. |
| `-e OFFLOADER_ADMIN_TOKEN` | Gates the admin `/diagnostics` route; unset means diagnostics is refused. |
| `-p 4000:4000` | **API port** — product traffic (API-key auth). Expose to your product. |
| `-p 127.0.0.1:4001:4001` | **Admin port** — health/metrics/diagnostics/docs. Bind to localhost or a private network; **do not expose it publicly.** |
| `-v .../etc/offloader:ro` | The config directory (`offloader.yml` + `datasets/`, `endpoints/`, `keys/`, and data). Read-only. |
| `-v offloader-cache:/var/lib/offloader/cache` | Persistent DuckDB materialization cache. A named volume survives restarts (warm cache). |

## Verify

```sh
curl -fsS http://127.0.0.1:4001/ready          # 200 once a snapshot is materialized
curl -H "Authorization: Bearer <api-key>" \
  http://localhost:4000/v1/endpoints/<endpoint>?<params>
```

## Upgrade / rollback

- **Upgrade:** pull the new pinned tag, stop the old container, start the new one.
  The cache volume rematerializes from the manifest on boot; there is no migration.
- **Rollback:** start the previous tag again. Health returns immediately.
- **Cache rebuild:** delete the cache volume (`docker volume rm offloader-cache`)
  and restart — the server rematerializes from the current manifest.
