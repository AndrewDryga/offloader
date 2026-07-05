# Security Model

Offloader runs **in your environment** and serves **read-only** data. This page explains,
in plain terms, what it protects for you and what you remain responsible for. (Newer to the
concepts? See [What Offloader is](concepts.md).)

## The short version

Everything stays in your environment — the data, the config, the logs, the
metrics. Offloader makes no outbound telemetry calls.

Consumers never get SQL access. They reach data only through the **named
endpoints** you define, on the API port, with an **API key** you issue. Each key
is scoped to specific endpoints and bound to **one tenant** (customer/account),
and Offloader inserts the tenant filter itself — a caller cannot widen it or
read another tenant's rows.

Operator surfaces (docs, metrics, diagnostics) live on a **separate admin port**
that **you** keep private. Offloader is not a login or identity product.

## Who can reach what

| Port | Who | What they get | Guarded by |
| --- | --- | --- | --- |
| **API (4000)** | your product / consumers | only the endpoints their key is granted, only their tenant's rows, only allowed columns | the API key + rules Offloader enforces (below) |
| **Admin (4001)** | your operators | health, metrics, generated docs, diagnostics | **you** — network / firewall / proxy / IAM. Keep it off the public internet. |

An API key is a bearer token you mint with `offloader keys create`. Only its **SHA-256 hash**
is stored in config — never the token itself. Revoke a key by changing its status; it's denied
immediately.

## What Offloader enforces (you get these for free)

A consumer can never send SQL — the only thing they can call is an endpoint you
declared. Their key works only on the endpoints granted to it, and the tenant
filter comes from the key itself, inserted server-side; no request parameter can
override it. Columns are locked down the same way: an endpoint can return only
its declared columns, and that allowlist is checked before the query ever runs.

Errors don't leak information either. Calling a forbidden endpoint returns the
**same** response as calling one that doesn't exist, so a probing caller can't
map out what's there.

Secrets stay out of the open. Logs, metrics, diagnostics, and support bundles
never include API keys, tokens, credentialed URLs, or raw request params by
default — bundles are redacted and list exactly what's inside. And the intended
posture for object-store credentials is **read-only**: Offloader only ever reads
snapshots, so that's all its credentials should allow.

## What you're responsible for

Three things stay on your side. You decide how the **admin port** is reached —
Offloader ships the two-port separation and the redaction, but whether that
means loopback, an internal network, a proxy, or your IAM is your call. You put
**TLS and ingress** in front of the API port. And you own the **snapshot
pipeline** that publishes data to object storage, along with the object-store
permissions themselves.

Offloader does **not** provide RBAC, SSO, org/team management, or a hosted control plane. If you
need enterprise access controls, run the admin port behind the ones you already use.

## Co-hosting config in the bucket

If you load config from a bucket (`OFFLOADER_CONFIG=gs://…`), the config tree includes the keys
file — but keys are stored as **hashes, never tokens**, so bucket-read exposure leaks hashes plus
the endpoint/tenant access map, not usable credentials. A **public** deployment (`auth: none`)
has no keys file at all. For an authed deployment, put the config under a **tighter-ACL
bucket/prefix** than the bulk data if you want to limit who can read the hashes.

## How it's proven

An adversarial security test suite exercises the invariants above on every build: API-key
bypass attempts, tenant-override attempts, column
selection outside the allowlist, param/filter injection, admin surfaces not reachable on the API
port, secret redaction in logs and bundles, and safe rollback of a failed snapshot.
