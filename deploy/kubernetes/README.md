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
  `datasets/`, `endpoints/`, and `keys/` the way that fits you — more ConfigMap keys,
  a git-sync sidecar, or a config image mounted at `/etc/offloader` — or skip the mount
  entirely and point `OFFLOADER_CONFIG` at a `gs://`/`s3://` bucket.
- **Exposure** — front `offloader-api` with your own Ingress/Gateway + TLS. Keep
  `offloader-admin` internal (ClusterIP); **never** put it behind a public Ingress —
  it serves diagnostics/metrics/docs and is not an identity product.

## Upgrade / rollback

- Upgrade: bump the pinned image tag and `kubectl apply` — a normal rolling update.
- Rollback: `kubectl rollout undo deploy/offloader`.
- Cache rebuild: delete the PVC (or `kubectl delete pod` with a fresh PVC) — the
  server rematerializes from the manifest on boot.
