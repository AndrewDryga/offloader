# Security Model

Offloader is a customer-run data-serving container. Treat configs, manifests,
query params, object-store paths, logs, support bundles, diagnostics, and metrics
as potentially sensitive.

## P0 requirements

- No arbitrary SQL exposed to consumers.
- API keys are hashed at rest and revocable.
- Consumer keys are scoped to explicit endpoints.
- Tenant binding is enforced server-side.
- Column allowlists are enforced before execution.
- Docs, schema, diagnostics, and metrics live on a separate admin port.
- Read-only object-store credentials.
- Stable security errors do not reveal forbidden dataset existence.
- Logs and metrics never include raw API keys, tokens, credentialed URIs, or
  unredacted params by default.
- Support bundles are redacted and include a manifest of included artifacts.
- No RBAC, SSO, organization model, team management, or hosted control plane in
  V1. Customers own access to the admin port with their existing network and
  identity controls.

## Customer-run boundary

Raw serving data, metadata, manifests, schemas, logs, metrics, and diagnostics
stay in the customer's environment by default. Offloader should not make outbound
calls for telemetry in V1. Support bundles are operator-created artifacts and are
shared only when the customer chooses to share them.

Do not claim that access control is solved by the product. The product provides
separate ports and redaction; the customer decides how the admin port is exposed,
proxied, authenticated, or firewalled.

## Required tests

- API key bypass attempts.
- Tenant parameter override attempts.
- Column selection outside allowlist.
- Params/filter injection.
- Docs/schema/diagnostics not exposed on the API port.
- Secret redaction in logs and support bundle.
- Failed manifest rollback.
