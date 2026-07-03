# Serving public data (front-end + CDN)

The common case Offloader is built for: **public, product-facing data** your team builds in the
warehouse and ships to a front-end — leaderboards, public stats pages, embedded charts. High
request volume, no per-user data, a few minutes' staleness is fine. This page shows how to serve
it cheaply and cache it at the edge.

## 1. Run it public

Set `auth: none` in `offloader.yml`. The API then needs no bearer token — accepted only when **no
endpoint is tenant-scoped** (enforced at config load), so it can never expose per-tenant data
unauthenticated.

```yaml
version: 1
auth: none
datasets_dir: datasets
endpoints_dir: endpoints
```

A call is just:

```sh
curl "https://api.example.com/v1/endpoints/champion?champion_id=1"
```

## 2. It's cacheable by construction

An Offloader response is **immutable for its `snapshot_id`** — the same params against the same
snapshot always return the same bytes, and a new snapshot changes them. So public responses carry:

- **`ETag`** — a fingerprint of `(endpoint, params, snapshot_id)`. A client or CDN revalidates with
  `If-None-Match`; if nothing changed, Offloader returns a bodyless **`304 Not Modified`** — near-free.
- **`Cache-Control: public, max-age=<n>, stale-while-revalidate=60`** — `max-age` is derived from the
  endpoint's `freshness.max_staleness_minutes` (capped at 1 hour), so a cache holds the response
  exactly as long as it's considered fresh, then revalidates by ETag.

Authed (non-public) responses instead get **`Cache-Control: private, no-store`** — per-tenant data
never lands in a shared cache.

## 3. Put a CDN in front

Point your CDN (CloudFront, Fastly, Cloudflare, …) at the Offloader API origin. Because the origin
sets proper `Cache-Control`/`ETag`, the CDN caches each response for its freshness window and
serves the vast majority of traffic from the edge — the origin sees mostly cheap `304`
revalidations. That's where "serving cost approaches zero, latency goes global" comes from: your
container materializes once per snapshot; the edge does the fan-out.

> **Managed edge (optional).** For public data, Offloader can also run this edge for you as a paid
> add-on — quoted per case, on the same share-of-savings basis. Because the data is already public,
> nothing private leaves your environment. Everything on this page works with **your own** CDN too;
> the managed option is just convenience.

## 4. Calling from a browser (CORS)

A same-origin front-end (served behind the same CDN/domain) needs nothing. For a **cross-origin**
browser call, set the allowed origins:

- `OFFLOADER_CORS_ORIGINS=*` — for a fully public API. Sends `Access-Control-Allow-Origin: *`.
- `OFFLOADER_CORS_ORIGINS=https://app.example.com,https://www.example.com` — echoes a listed origin
  and allows credentials (for an authed API). An off-list origin gets no CORS headers.

Preflight `OPTIONS` requests are answered directly (before auth), so a browser `fetch` just works.

## 5. Protect it

`auth: none` has no per-client quota — an abusive client just saturates the DuckDB pool, which sheds
excess as `503` (safe, but not fair). For a public endpoint, put **rate limiting / WAF at your CDN
or ingress** — the same layer already doing the edge caching. Keep the Offloader admin port private
regardless (it's not part of the public surface).

## What "approaches zero" assumes

The cost win is real but conditional: it assumes a **high cache-hit ratio** (many repeated reads of
a bounded set of params) and a freshness window long enough for the edge to hold responses. If every
request has unique params, or you need per-second freshness, the edge can't help — see
[Fit](concepts.md#is-it-a-fit). Measure your real hit ratio before quoting a number.
