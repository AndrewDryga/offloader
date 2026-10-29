# Serving your endpoints to AI agents (MCP)

Your warehouse builds a dataset. Offloader already serves it as a REST endpoint your app calls.
This page adds a second door onto the **same** endpoints so an AI agent — Claude, an internal
copilot, anything that speaks the Model Context Protocol — can read them too.

Nothing new is exposed. An agent sees exactly the endpoints you configured, with the same
params, the same column allowlist, and the same tenant filter. There is no way to send SQL.

## Turn it on

Off by default. Set one environment variable:

```sh
OFFLOADER_MCP_ENABLED=true
```

The agent then points at one URL on the normal API port:

```
POST https://api.example.com/mcp
```

That's the whole setup. Offloader speaks MCP revision **`2026-07-28`**, which is stateless —
there is no connection to open, no session to keep alive, and no separate event stream. Each
request stands alone, which is what makes the rest of this page possible.

Clients on the older `initialize` handshake (revisions `2025-03-26` through `2025-11-25`), which
many agent tools still use, work on the same URL. Offloader answers their `initialize` without
opening a session, so their requests stand alone too. They read the same endpoints with the same
keys and tenant filters. What they lack are the mirrored headers described
[below](#caching-at-the-edge), so their responses are never cacheable, and edge rules keyed on
those headers don't apply to them.

## What an agent sees

Every endpoint you've configured shows up twice, because the protocol has two ways to read data
and they behave differently:

| Surface | Agent calls | Cacheable? |
| --- | --- | --- |
| **Tool** | `tools/call` with your params as arguments | No — the protocol defines no cache fields for tool results |
| **Resource** | `resources/read` with an `offloader://` URI | **Yes** |

Both run the identical query. Publish both and the agent picks; an agent framework will usually
reach for the tool, while a high-volume deployment wants the resource.

A tool is generated from the endpoint contract, so its description and its input schema already
match what the server enforces:

```jsonc
{
  "name": "customer_usage_summary",
  "description": "Total active users, API calls, and average storage per account over a date range. Returns rows with: account_id, active_users_total, api_calls_total, storage_gb_avg. Data comes from a snapshot and may be up to 120 minutes old.",
  "inputSchema": {
    "type": "object",
    "properties": { "account_id": {…}, "from": {…}, "to": {…}, "limit": {…}, "offset": {…}, "columns": {…} },
    "required": ["from", "to"],
    "additionalProperties": false
  }
}
```

The same endpoint as a resource template, with its params as an RFC 6570 query expansion:

```
offloader://customer_usage_summary{?account_id,from,to,limit,offset,columns}
```

Filled in, that's a resource URI the agent reads:

```
offloader://customer_usage_summary?from=2026-05-30&to=2026-06-01
```

The response body is the same JSON the REST endpoint returns — the `data` array plus the `meta`
block with `snapshot_id` and `freshness`. Nothing is reshaped for MCP.

## Caching at the edge

This is the part worth understanding, because it decides how much traffic ever reaches your
server.

A `resources/read` result carries two fields the protocol defines for caching:

- **`ttlMs`** — how long the result stays fresh. Derived from the endpoint's
  `freshness.max_staleness_minutes`, capped at one hour.
- **`cacheScope`** — `"public"` if a **shared** cache (a CDN) may hold it, `"private"` if not.

An agent's MCP client uses them to reuse a fresh result instead of asking again.

`cacheScope` is `"public"` only when the response has no tenant attached — that is, when you run
`auth: none` and the endpoint is not tenant-scoped. It is exactly the same decision the REST path
makes when it chooses between `Cache-Control: public, max-age=…` and `private, no-store`, taken in
one place so the two can never drift. **A tenant-scoped read is never advertised as shareable.**

Offloader also restates that decision as a normal HTTP `Cache-Control` header on the MCP response,
because a CDN can't read a field out of a JSON-RPC body.

### How a CDN keys the cache

MCP is a POST to a single URL, so at first glance there's nothing to cache on. The `2026-07-28`
revision solves this by requiring the client to mirror the important parts of the body into HTTP
headers:

```http
POST /mcp HTTP/1.1
MCP-Protocol-Version: 2026-07-28
Mcp-Method: resources/read
Mcp-Name: offloader://customer_usage_summary?from=2026-05-30&to=2026-06-01
```

`Mcp-Method` names the operation and `Mcp-Name` carries the **whole resource URI**, endpoint and
params together. The two headers make a complete cache key, so an edge can cache, route, and
rate-limit without parsing the body.

Offloader **requires** those headers on `2026-07-28` requests and rejects one whose headers
disagree with its body (`-32020 HeaderMismatch`), including an `Mcp-Name` on a method that has no
name. That strictness is the point: a cache keyed on these headers is only safe if the server
refuses to execute anything else.

Older clients don't send the mirrored headers, so there is nothing to check them against. Their
responses carry no `ttlMs` or `cacheScope` and always come back `private, no-store`, even for
public data and even if the request carries an `Mcp-Name` header.

> Caching POST responses is not a CDN default, and a plain cache rule isn't enough. The cached body
> carries the JSON-RPC `id` of the request that filled the cache, and MCP clients match responses
> by `id`, so you need an edge function that puts each request's `id` into the cached response.
> Key the cache on `Mcp-Method` plus `Mcp-Name`, and only for requests that send
> `MCP-Protocol-Version: 2026-07-28`. Cache only responses that Offloader marks
> `Cache-Control: public` (it does this only in an `auth: none` deployment), and keep the cache
> lifetime it sends. Authenticated reads come back `private, no-store`. Never put them in a shared
> cache. Public reads carry the same `CDN-Tag` as the REST response for that endpoint, so one tag
> purge covers both surfaces.
>
> The same goes for routing or rate limits keyed on these headers: apply them only to `2026-07-28`
> requests. An older client's request doesn't carry the headers, so limit it some other way (by
> key or IP) or turn it away at the edge.

## Authentication

Identical to the REST path, because it's the same key model:

- **`auth: none` project** — no token needed; every endpoint is visible.
- **Otherwise** — send `Authorization: Bearer <api-key>`. The key's endpoint allowlist and its
  bound tenant apply exactly as they do over REST.

Discovery is scoped to the key. `tools/list` and `resources/templates/list` return **only** the
endpoints that key grants, so an agent never learns that an endpoint it can't call exists. Calling
one anyway returns the same `not found` an unknown endpoint returns.

`server/discover` and `initialize` answer without a key: they report protocol versions and
capabilities, never data or endpoint names.

## Supported methods

| Method | Purpose |
| --- | --- |
| `server/discover` | Protocol versions + capabilities. No key required. |
| `initialize` | For clients on the older handshake: agrees on a version. No key required, and no session is created. |
| `ping` | For clients on the older handshake. |
| `tools/list` | Your endpoints as tools, scoped to the key. |
| `tools/call` | Run one endpoint. |
| `resources/list` | Endpoints readable with no arguments. |
| `resources/templates/list` | Every endpoint as a URI template, scoped to the key. |
| `resources/read` | Run one endpoint by URI. The cacheable path. |

Not implemented: `prompts/*`, `subscriptions/listen`, sampling, elicitation, and roots. Offloader
serves data and never needs to ask the client for anything. A snapshot swap is picked up when
`ttlMs` expires rather than pushed as a notification. Older clients get no event stream and have
no session to end, so `GET /mcp` and `DELETE /mcp` return 405. JSON-RPC batches, which only
`2025-03-26` allowed, are refused: send one request per POST.

## Errors

| Situation | What comes back |
| --- | --- |
| Missing or bad bearer token | HTTP 401 |
| Service still starting | HTTP 503 |
| Missing, mismatched, or misplaced `Mcp-Method`, `Mcp-Name`, or version header (`2026-07-28` requests) | HTTP 400, code `-32020` |
| Protocol version we don't speak | HTTP 400, code `-32022`, listing every version we do |
| Unknown method | HTTP 404, code `-32601` (HTTP 200 for a client on the older handshake) |
| `GET` or `DELETE` on `/mcp` | HTTP 405 |
| A JSON-RPC batch | HTTP 400, code `-32600` |
| Bad param, or an endpoint the key can't reach — on `tools/call` | HTTP 200, `isError: true` |
| Same, on `resources/read` | HTTP 200, code `-32602` |

Application errors come back as tool errors on purpose: the model can read the message and fix its
own call, which it can't do with a protocol-level failure.

## One thing to think about before enabling it

Rows you serve land in a model's context, and a model reads its context as instructions. If any
column contains text a third party can write — a support ticket, a product review, a user-supplied
name — treat that the same way you'd treat rendering it as HTML. Offloader tells the model to treat
returned rows as data rather than instructions, but that is a hint, not a boundary. If it matters,
keep those columns out of the endpoint's allowlist.

This is a genuine difference from the REST path, where responses go to your application code
instead of into a model's context.
