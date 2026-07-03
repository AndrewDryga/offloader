# Security policy

Offloader is a self-hostable container. You run it in your own environment, so you own
its network exposure, credentials, and patch cadence — but the code's security is ours.

## Reporting a vulnerability

Email **andrew@dryga.com** with:

- a description of the issue and its impact,
- steps to reproduce (a minimal config/manifest is ideal), and
- the affected version or commit.

Please report privately first — do not open a public issue for a suspected
vulnerability. We aim to acknowledge within **3 business days** and to agree on a
disclosure timeline with you. We credit reporters who want it.

## Supported versions

During pre-1.0 development, only the latest tagged release (and `main`) receives security
fixes. Pin a released image tag (never `:latest`) and upgrade to take a fix.

## What the product enforces

The security model is documented in [docs/security-model.md](docs/security-model.md) and
exercised by an adversarial test suite in CI. In brief:

- **Tenant isolation is server-side.** The tenant filter is compiled in from the caller's
  API key; a request cannot widen it or read another tenant's rows, and there is no
  arbitrary SQL. `auth: none` (public) is accepted only when no endpoint is tenant-scoped.
- **Keys are stored as SHA-256 hashes**, compared in constant time; plaintext is never
  persisted.
- **Two ports.** Product traffic (API) and operator surfaces (admin: metrics,
  diagnostics, generated docs) are separate; keep the admin port private. The admin
  token fails closed when unset.
- **Credentials stay out of output.** API keys, object-store secrets, and bearer tokens
  are kept out of responses, logs, error bodies, diagnostics, and support bundles
  (redaction is best-effort over known secret shapes — review a bundle before sharing).

## Your responsibilities (self-hosted)

Network placement and TLS termination, keeping the admin port private, object-store IAM
and bucket ACLs, secret management for the env vars, OS/container patching, and rate
limiting / WAF in front of a public (`auth: none`) endpoint. See
[docs/operations/ownership.md](docs/operations/ownership.md).
