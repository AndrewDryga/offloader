# Kubernetes

`offloader.yaml` is a provider-neutral skeleton: Secret, ConfigMap, cache PVC,
Deployment (non-root, read-only root FS, probes on the admin port), and **two
Services** — `offloader-api` (product traffic) and `offloader-admin` (operators).

```sh
# fill in the Secret values and your config first, then:
kubectl apply -f offloader.yaml
kubectl rollout status deploy/offloader
```

## You adapt

- **Secrets** — replace the placeholders in the `Secret` (or use your external
  secrets operator). `OFFLOADER_SECRET_KEY_BASE` is required; `OFFLOADER_ADMIN_TOKEN`
  gates `/diagnostics`.
- **Config** — the example ships only `offloader.yml` in the ConfigMap. Supply
  `datasets/`, `endpoints/`, and `keys/` the way that fits you: more ConfigMap keys,
  a git-sync sidecar, a config image, or (later) remote object-store mode. Mount the
  full config directory at `/etc/offloader`.
- **Exposure** — front `offloader-api` with your own Ingress/Gateway + TLS. Keep
  `offloader-admin` internal (ClusterIP); **never** put it behind a public Ingress —
  it serves diagnostics/metrics/docs and is not an identity product.

## Upgrade / rollback

- Upgrade: bump the pinned image tag and `kubectl apply` — a normal rolling update.
- Rollback: `kubectl rollout undo deploy/offloader`.
- Cache rebuild: delete the PVC (or `kubectl delete pod` with a fresh PVC) — the
  gateway rematerializes from the manifest on boot.

## Non-goals

No provider-specific Terraform, hosted control plane, RBAC, or SSO. Customers own
their cluster, network, IAM, and ingress story.
