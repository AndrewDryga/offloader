# Security Model

Offloader runs **in your environment** and serves **read-only** data. This page explains,
in plain terms, what it protects for you and what you remain responsible for. (Newer to the
concepts? See [What Offloader is](concepts.md).)

## The short version

- Your data, config, logs, and metrics **stay in your environment**. Offloader makes no
  outbound telemetry calls.
- Consumers reach data only through **named endpoints** on the API port, using an **API key**
  you issue. There is no arbitrary SQL.
- Each key is scoped to **specific endpoints** and bound to **one tenant** (customer/account).
  Offloader inserts the tenant filter itself — a caller **cannot** widen it or read another
  tenant's rows.
- Operator surfaces (docs, metrics, diagnostics) are on a **separate admin port** that **you**
  keep private. Offloader is not a login/identity product.

## Who can reach what

| Port | Who | What they get | Guarded by |
| --- | --- | --- | --- |
| **API (4000)** | your product / consumers | only the endpoints their key is granted, only their tenant's rows, only allowed columns | the API key + rules Offloader enforces (below) |
| **Admin (4001)** | your operators | health, metrics, generated docs, diagnostics | **you** — network / firewall / proxy / IAM. Keep it off the public internet. |

An API key is a bearer token you mint with `offloader keys create`. Only its **SHA-256 hash**
is stored in config — never the token itself. Revoke a key by changing its status; it's denied
immediately.

## What Offloader enforces (you get these for free)

- **No arbitrary SQL** reaches consumers — only your declared endpoints.
- **Endpoint allowlist** per key: a key can call only the endpoints granted to it.
- **Tenant isolation:** the tenant filter is inserted server-side from the key and cannot be
  overridden by a request parameter.
- **Column allowlist:** an endpoint can return only its declared columns — checked before the
  query runs.
- **Safe errors:** a forbidden endpoint and a non-existent one return the **same** response, so
  probing can't discover what exists.
- **Secrets stay out of the open:** logs, metrics, diagnostics, and support bundles never
  include API keys, tokens, credentialed URLs, or raw params by default; support bundles are
  redacted and list what's inside.
- **Read-only object-store credentials** are the intended posture — Offloader only reads snapshots.

## What you're responsible for

- **Exposing the admin port safely.** Offloader ships the separation (two ports) and redaction;
  you decide how the admin port is reached — loopback, an internal network, a proxy, or your IAM.
- **TLS and ingress** in front of the API port.
- **The snapshot pipeline** that publishes data to object storage, and the object-store
  permissions themselves.

Offloader does **not** provide RBAC, SSO, org/team management, or a hosted control plane. If you
need enterprise access controls, run the admin port behind the ones you already use.

## Co-hosting config in the bucket

If you load config from a bucket (`OFFLOADER_CONFIG=gs://…`), the config tree includes the keys
file — but keys are stored as **hashes, never tokens**, so bucket-read exposure leaks hashes plus
the endpoint/tenant access map, not usable credentials. A **public** deployment (`auth: none`)
has no keys file at all. For an authed deployment, put the config under a **tighter-ACL
bucket/prefix** than the bulk data if you want to limit who can read the hashes.

## How we prove it

An adversarial test suite (`server/test/offloader/security_suite_test.exs`) exercises the
invariants above on every build: API-key bypass attempts, tenant-override attempts, column
selection outside the allowlist, param/filter injection, admin surfaces not reachable on the API
port, secret redaction in logs and bundles, and safe rollback of a failed snapshot.
