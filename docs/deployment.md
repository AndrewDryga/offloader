# Deployment

Offloader is a self-hosted container. It ships an image, documented env vars, mounted-config
conventions, health checks, metrics, and smoke tests — you decide how to run it (VMs,
Kubernetes, Nomad, ECS, or your own platform).

## Runtime shape

Two ports, with different audiences:

<figure class="flow" aria-label="Product traffic hits the API port (4000), guarded by endpoint API keys and tenant enforcement. Operators hit a separate admin port (4001) for health, metrics, diagnostics, and docs — keep it private.">
  <div class="ports">
    <div class="node node-hero"><span class="node-k">Product traffic</span><strong>API port · 4000</strong><span class="node-sub">endpoint API keys · tenant enforcement</span></div>
    <div class="node"><span class="node-k">Operators — keep private</span><strong>Admin port · 4001</strong><span class="node-sub">health · metrics · diagnostics · docs</span></div>
  </div>
</figure>

The admin port is not an identity product — expose it only through your own network, proxy,
firewall, or IAM.

**Config** comes from `OFFLOADER_CONFIG`: either a mounted directory (a ConfigMap/volume with
`offloader.yml` + `datasets/`/`endpoints/`/`keys/`) or a `gs://…` bucket prefix fetched at boot
(fully stateless). With `OFFLOADER_CONFIG_SYNC_INTERVAL` set, bucket changes hot-reload with no
restart — see the [config guide](developer-experience.md#config-from-object-storage-optional).

## Deployment examples

Provider-neutral, ready-to-adapt examples live in [`deploy/`](../deploy/README.md):

- [`docker-run/`](../deploy/docker-run/README.md) — single-node `docker run`.
- [`compose/`](../deploy/compose/README.md) — Docker Compose with a persistent cache volume.
- [`kubernetes/`](../deploy/kubernetes/README.md) — Deployment, Services, ConfigMap, Secret, PVC, health probes, resource limits.
- [`prometheus/`](../deploy/prometheus/README.md) — scrape config + ServiceMonitor for the admin port.

## Rollout verification and rollback

Deploy the **published, signed image** (`ghcr.io/andrewdryga/offloader:<version>`), then verify
the running instance. Wrap these four checks in your own deploy-verification step, run against a
freshly-deployed instance before it takes traffic:

1. Wait for the admin `/ready` to return 200 (it stays 503 until a snapshot is
   materialized, so traffic is held until the instance can actually serve).
2. Confirm `/live`, `/status`, `/metrics`, and authenticated `/diagnostics`.
3. Call one real endpoint with a known key and assert `snapshot_id` + freshness.
4. Confirm the admin surface is NOT reachable on the API port.

If a check fails, roll back:

- **Bad image or config** — redeploy the previous image tag (pin versions; never
  `:latest`). Health returns immediately; there is no schema migration to undo.
- **Bad snapshot** — the server never swaps in a snapshot that fails validation or
  compatibility, so serving is already protected. To revert a *good-but-wrong*
  snapshot, roll the dataset back to its previous good snapshot (see
  [runbooks](operations/runbooks.md) → "Rollback to previous snapshot").
