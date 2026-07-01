# deploy

This directory holds customer-run deployment examples for the Offloader
container. Keep examples provider-neutral unless a paid pilot proves a specific
platform recipe is worth maintaining.

Expected examples:

- `docker-run/`
- `compose/`
- `kubernetes/`
- `prometheus/`

Do not add a hosted cloud control plane, provider-specific Terraform baseline, or
RBAC/SSO implementation here.
