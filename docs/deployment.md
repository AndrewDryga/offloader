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

## Non-goals

- No hosted Offloader cloud.
- No Terraform module for a specific provider in V1.
- No RBAC, SSO, organization management, or team management.
- No fleet management portal.
