# Security Model

Offloader runs **in your environment** and serves **read-only** data. This page explains,
in plain terms, what it protects for you and what you remain responsible for. (Newer to the
concepts? See [How Offloader works](concepts.md).)

## The short version

Everything stays in your environment — the data, the config, the logs, the
metrics. Offloader makes no outbound telemetry calls. The only exception is the optional
[managed CDN edge](public-serving.md) for public data, if you buy it. Put it only in front
of a public (`auth: none`) hostname, where it sees the same responses any visitor can
request. Offloader does not check where you put it, so never send authenticated or
tenant-scoped traffic through it.

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

If you switch on the [agent surface](mcp.md) (`OFFLOADER_MCP_ENABLED`, off by default), it shares
the API port and the row above: an agent is just another consumer holding an API key, reading the
same endpoints. It gets no wider reach than that key already had — including which endpoints it
can even see listed.

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

These are properties of the serving path, not of one protocol, so they hold identically for
an agent reading over [MCP](mcp.md): the same compiled query, the same key check, the same
inserted tenant filter, the same column allowlist.

Compressed responses don't open a BREACH-style leak, which needs another site to make a visitor's
browser send authenticated requests. A key travels in the `Authorization` header, never in a
cookie, so a browser doesn't attach it on its own, and public responses hold no secrets.

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

Treat `auth: none` as publishing. Anyone who can reach the API port can read every
endpoint, and a private network alone doesn't change that: a web page can use DNS rebinding
to make a visitor's browser read an internal address. On a private network, set
`OFFLOADER_ALLOWED_HOSTS` to the names your clients use. Offloader then refuses a request
addressed to any other name, and a rebinding page can only send a name the attacker owns.
If the data isn't meant to be public at all, give it API keys. A browser never sends those
on its own.

That check only helps if nothing else lets a web page in. On a private network, don't set
`OFFLOADER_CORS_ORIGINS=*`: it lets any page read the API by its real name, no rebinding needed,
so list the origins that may call it instead. Behind a proxy, forward the client's `Host`
(nginx: `proxy_set_header Host $host`) or enforce the names at the proxy, because a proxy that
rewrites `Host` to its upstream address makes every request look allowed. Requests addressed to an
IP address or to `localhost` always pass, since a rebinding page can't send those. The setting
covers the API port only: the admin port's open pages (docs, schema, metrics and status) hold no
data, but keep that port off networks people browse from.

A fourth applies only if you enable the [agent surface](mcp.md): **what your columns
contain.** Rows served to an agent land in a model's context, and a model reads its
context as instructions. If a column holds text an outsider can write — a support ticket,
a review, a profile name — treat serving it to an agent the way you'd treat rendering it
as HTML. Offloader tells the model to read rows as data rather than instructions, but that
is a hint, not a boundary; the enforceable control is the endpoint's column allowlist. This
is a real difference from REST, where responses go to your code instead of into a model's
context.

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

The agent surface is held to the same bar: tenant values smuggled through a resource URI or a
tool argument, discovery scoped so a key never sees an endpoint it can't call, two keys reading
the same endpoint getting disjoint rows, and a per-customer read never being advertised as
cacheable by a shared CDN.
