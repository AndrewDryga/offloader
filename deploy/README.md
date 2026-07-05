# deploy

Customer-run deployment examples for the Offloader container. Offloader ships an
image, env vars, mounted-config conventions, health checks, and metrics; **you**
decide how to run it (VM, Kubernetes, Nomad, ECS, …). These examples are
provider-neutral and show the container's shape, not your production network.

## Examples

- [`docker-run/`](docker-run/README.md) — single-node `docker run`.
- [`compose/`](compose/README.md) — Docker Compose with a mounted cache volume.
- [`kubernetes/`](kubernetes/README.md) — Deployment, Services, ConfigMap, Secret, PVC.
- [`prometheus/`](prometheus/README.md) — scrape config + ServiceMonitor for `/metrics`.

## The shape every deployment shares

| Concern | What Offloader needs |
| --- | --- |
| **API port** (4000) | Product traffic, API-key auth. Front it with your ingress/TLS. |
| **Admin port** (4001) | Health/metrics/diagnostics/docs. **Keep it private** — bind to loopback or an internal network; it is not an identity product. |
| **Config** | `OFFLOADER_CONFIG` — a mounted directory (`offloader.yml` + `datasets/`, `endpoints/`, `keys/`) **or** a `gs://…` bucket prefix, fetched at boot (fully stateless, nothing mounted). |
| **Cache** | A persistent volume at `/var/lib/offloader/cache` (warm restarts). |
| **Secrets** | `OFFLOADER_SECRET_KEY_BASE` (required), `OFFLOADER_ADMIN_TOKEN` (gates diagnostics) — from env vars or your secret store, never baked into the image. |
| **Image** | **Pull from GHCR** and pin a released tag (`ghcr.io/andrewdryga/offloader:0.1.5`); never `:latest`. The rolling `:edge` tag tracks `main`. Upgrade = new tag; rollback = old tag. |

Deploy the **published, signed image**, then verify the running instance — see
[rollout verification and rollback](../docs/deployment.md) for the exact checks.
