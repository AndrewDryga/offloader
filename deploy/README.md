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
| **Config** | A mounted directory with `offloader.yml` + `datasets/`, `endpoints/`, `keys/`, at `OFFLOADER_CONFIG`. |
| **Cache** | A persistent volume at `/var/lib/offloader/cache` (warm restarts). |
| **Secrets** | `OFFLOADER_SECRET_KEY_BASE` (required), `OFFLOADER_ADMIN_TOKEN` (gates diagnostics) — from env vars or your secret store, never baked into the image. |
| **Image** | Pin a version (`ghcr.io/OWNER/offloader:1.0.0`); never `:latest`. Upgrade = new tag; rollback = old tag. |

Before rolling out, run `make deploy-check` (builds + boots + verifies the image).
See [`../docs/deployment.md`](../docs/deployment.md) for rollout verification and
rollback.

## Non-goals

No hosted cloud control plane, no provider-specific Terraform baseline, no RBAC/SSO
implementation. Customers own their cloud, network, IAM, and firewall story.
