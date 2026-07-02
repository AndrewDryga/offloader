# Deployment

Offloader V1 is a customer-run container. The product ships an image, documented
env vars, mounted config conventions, health checks, metrics, and smoke tests.
Customers decide how to run it on their servers, Kubernetes clusters, Nomad
clusters, ECS tasks, VMs, or other internal platforms.

## Runtime shape

```text
product traffic -> API port      -> endpoint API keys and tenant enforcement
operators       -> admin port    -> health, readiness, metrics, diagnostics, docs
```

The admin port is not an identity product. Customers expose it only through their
own network, proxy, firewall, IAM, SSO, or RBAC controls.

## Required examples

- Single-node `docker run`.
- Docker Compose with a mounted cache volume.
- Kubernetes Deployment, Service, ConfigMap, Secret, and PersistentVolumeClaim.
- Prometheus scrape config for the admin port.
- Rollback to previous image.
- Cache quarantine and rebuild.

## Rollout verification and rollback

Before rolling out an image, run the same gate the project uses:

```sh
make deploy-check   # builds the prod image, boots it, verifies ports, health,
                    # diagnostics/metrics, and a manifest -> HTTP smoke, then exits 0
```

`dev/scripts/deploy-check.sh` is the reusable shape — a customer's deployment
system can wrap the same checks against a freshly-deployed instance:

1. Wait for the admin `/ready` to return 200 (it stays 503 until a snapshot is
   materialized, so traffic is held until the instance can actually serve).
2. Confirm `/live`, `/status`, `/metrics`, and authenticated `/diagnostics`.
3. Call one real endpoint with a known key and assert `snapshot_id` + freshness.
4. Confirm the admin surface is NOT reachable on the API port.

If a check fails, roll back:

- **Bad image or config** — redeploy the previous image tag (pin versions; never
  `:latest`). Health returns immediately; there is no schema migration to undo.
- **Bad snapshot** — the gateway never swaps in a snapshot that fails validation or
  compatibility, so serving is already protected. To revert a *good-but-wrong*
  snapshot, roll the dataset back to its previous good snapshot (see

## Non-goals

- No hosted Offloader cloud.
- No Terraform module for a specific provider in V1.
- No RBAC, SSO, organization management, or team management.
- No fleet management portal.
