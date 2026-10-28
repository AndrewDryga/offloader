defmodule OffloaderWeb.CachePolicy do
  @moduledoc """
  One decision, two surfaces: may a served response sit in a SHARED cache, and for
  how long. REST renders it as `Cache-Control`/`ETag`; MCP renders it as SEP-2549
  `cacheScope`/`ttlMs`. The two must never disagree — a response the REST path marks
  `private, no-store` must not be advertised to an MCP client as `cacheScope: "public"`,
  because that invites a CDN to serve one tenant's rows to another — so both read the
  decision from here rather than each deriving it.
  """

  alias Offloader.Runtime

  # Cap the advertised lifetime even when an endpoint declares a long freshness window:
  # revalidation (ETag on REST, a fresh read on MCP) covers the rest.
  @max_ttl_seconds 3600
  @default_ttl_seconds 60

  @doc """
  True when a response produced for `tenant` may be cached by a shared intermediary.

  The tenant guard is load-bearing and is NOT redundant with `Runtime.public?/0`:
  `public?/0` is a fresh catalog read that can race a hot reload flipping auth
  required→none, so the answer is tied to the tenant that actually produced these
  bytes, not to global state alone. A response built WITH a tenant filter is never
  shared-cacheable.
  """
  @spec shared?(String.t() | nil) :: boolean()
  def shared?(tenant), do: tenant == nil and Runtime.public?()

  @doc "Shared-cache lifetime for a served response, from its freshness window (capped)."
  @spec ttl_seconds(map()) :: pos_integer()
  def ttl_seconds(response) do
    case get_in(response, [:meta, :freshness, :max_staleness_minutes]) do
      minutes when is_integer(minutes) and minutes > 0 -> min(minutes * 60, @max_ttl_seconds)
      _ -> @default_ttl_seconds
    end
  end

  @doc """
  Lifetime for a discovery/list result. The catalog changes only on a config reload,
  so this is short enough that a hot reload propagates without a client restart.
  """
  @spec list_ttl_seconds() :: pos_integer()
  def list_ttl_seconds, do: @default_ttl_seconds

  @doc """
  The `CDN-Tag` for a served response a shared cache may store, or nil when it may not.

  The value is `offloader:<dataset>:<endpoint>`, so a CDN that purges by tag (bunny.net
  reads `CDN-Tag`) can drop `offloader:<dataset>:*` after new data lands, one endpoint by
  its exact tag, or everything with `offloader:*`. Dataset and endpoint names never
  contain `:`, so the parts cannot run together.
  """
  @spec cdn_tag(String.t() | nil, String.t()) :: String.t() | nil
  def cdn_tag(tenant, endpoint_name) do
    with true <- shared?(tenant),
         %{endpoints: %{^endpoint_name => %{dataset: dataset}}} <- Runtime.catalog() do
      "offloader:#{dataset}:#{endpoint_name}"
    else
      _ -> nil
    end
  end

  @doc "Adds the `CDN-Tag` header when `cdn_tag/2` gives one; private responses get none."
  @spec put_cdn_tag(Plug.Conn.t(), String.t() | nil, String.t()) :: Plug.Conn.t()
  def put_cdn_tag(conn, tenant, endpoint_name) do
    case cdn_tag(tenant, endpoint_name) do
      nil -> conn
      tag -> Plug.Conn.put_resp_header(conn, "cdn-tag", tag)
    end
  end
end
