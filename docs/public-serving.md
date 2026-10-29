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

An Offloader response is **immutable for its `snapshot_id`**: the same params against the same
snapshot always return the same data, and a new snapshot changes it. Only per-request metadata,
such as `request_id` and `generated_at`, differs between responses. So public responses carry:

- **`ETag`** — a weak validator (`W/"…"`) for `(endpoint, contract version, params, snapshot_id)`.
  It is weak because the per-request metadata makes each body slightly different. A client or CDN
  revalidates with `If-None-Match`; if nothing changed, Offloader returns a bodyless
  **`304 Not Modified`**, which costs almost nothing.
- **`Cache-Control: public, max-age=<n>, stale-while-revalidate=60`** — `max-age` is derived from the
  endpoint's `freshness.max_staleness_minutes` (capped at 1 hour), so a cache holds the response
  exactly as long as it's considered fresh, then revalidates by ETag.
- **`CDN-Tag: offloader:<dataset>:<endpoint>`** — a tag for CDNs that purge by tag (bunny.net
  reads this header, and its tag purge accepts wildcards). After a new snapshot lands, purge
  `offloader:<dataset>:*` to drop everything built from that dataset. Purge the exact tag to drop
  one endpoint, or `offloader:*` to drop everything Offloader served. Cloudflare and Fastly read
  other header names (`Cache-Tag`, `Surrogate-Key`).

Authed (non-public) responses instead get **`Cache-Control: private, no-store`** — per-tenant data
never lands in a shared cache.

Every response, public or authed, is compressed with zstd or gzip when the request's
`Accept-Encoding` allows it, and carries `Vary: Accept-Encoding` so caches keep the compressed and
plain copies apart. A public response's weak `ETag` covers all of its encodings.

## 3. Put a CDN in front

Point your CDN (CloudFront, Fastly, Cloudflare, …) at the Offloader API origin. Because the origin
sets proper `Cache-Control`/`ETag`, the CDN caches each response for its freshness window and
serves the vast majority of traffic from the edge — the origin sees mostly cheap `304`
revalidations. That's where "serving cost approaches zero, latency goes global" comes from: your
container materializes once per snapshot; the edge does the fan-out.

Large responses gain the most from the edge. Compression costs the origin CPU for every response it
sends. On an Apple M3 Pro with multi-megabyte JSON, gzip took up to about 17 ms per MB and zstd up
to about 3 ms, less for repetitive data. A CDN keeps the compressed copy, so the origin pays that
once per snapshot, URL and encoding at each edge cache (once in total behind an origin shield)
rather than on every request.

> **Managed edge (optional).** For public data, Offloader can also run this edge for you as a paid
> add-on — quoted per case, on the same share-of-savings basis. Because the data is already public,
> nothing private leaves your environment. Everything on this page works with **your own** CDN too;
> the managed option is just convenience.

The [agent surface](mcp.md) inherits this. A public read over MCP is marked `cacheScope: "public"`
from the same decision that produces `Cache-Control` here, and carries its entire cache key in one
request header — so the same CDN can serve agent reads too. It needs its own cache rule, because
MCP is a POST; see [AI agents](mcp.md#caching-at-the-edge). A per-tenant read is `private` on both
paths and belongs in no shared cache.

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
