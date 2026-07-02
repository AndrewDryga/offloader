# Docker Compose

Single-node Compose with a mounted config directory and a persistent cache volume.

```sh
# put your config in ./offloader (offloader.yml + datasets/endpoints/keys), then:
export OFFLOADER_SECRET_KEY_BASE=$(openssl rand -base64 48)
export OFFLOADER_ADMIN_TOKEN=$(openssl rand -base64 24)
docker compose up
```

- The **API port** (4000) is published for product traffic; the **admin port**
  (4001) is bound to `127.0.0.1` — reach it over your own private network, not the
  public internet.
- The cache is a named volume (`offloader-cache`) so materialized snapshots survive
  restarts.
- Pin the image tag; never `:latest`. Upgrade by changing the tag and
  `docker compose up -d`; roll back by changing it back.
