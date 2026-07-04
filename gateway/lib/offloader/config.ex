defmodule Offloader.Config do
  @moduledoc """
  Typed accessors for the container's env-var runtime contract.

  The primary V1 deployment interface is env vars + mounted config. `config/runtime.exs`
  parses the raw `OFFLOADER_*` env vars once at boot and places them in the `:offloader`
  application env; this module is the one place the rest of the gateway reads them, so
  env parsing and defaults never get duplicated. Documented in
  `docs/developer-experience.md` → "Required container env vars".
  """

  @doc "Path to the mounted config file (`OFFLOADER_CONFIG`), or nil if unset."
  @spec config_path() :: String.t() | nil
  def config_path, do: Application.get_env(:offloader, :config_path)

  @doc "Local cache/materialization directory (`OFFLOADER_CACHE_DIR`)."
  @spec cache_dir() :: String.t()
  def cache_dir, do: Application.get_env(:offloader, :cache_dir)

  @doc """
  Config auto-sync interval in milliseconds (`OFFLOADER_CONFIG_SYNC_INTERVAL`, seconds), or
  nil to disable. When set, `Offloader.Config.Sync` re-checks the config and hot-reloads it.
  """
  @spec config_sync_interval_ms() :: pos_integer() | nil
  def config_sync_interval_ms, do: Application.get_env(:offloader, :config_sync_interval_ms)

  @doc "Admin token (`OFFLOADER_ADMIN_TOKEN`) gating the admin `/diagnostics` route, or nil."
  @spec admin_token() :: String.t() | nil
  def admin_token, do: Application.get_env(:offloader, :admin_token)

  @doc """
  Allowed CORS origins for the product API (`OFFLOADER_CORS_ORIGINS`): `["*"]`, an explicit
  list of origins, or nil (no CORS headers — the default). Lets a browser front-end call the
  API directly; `*` suits a public API, an explicit list suits an authed one (credentials).
  """
  @spec cors_origins() :: [String.t()] | nil
  def cors_origins, do: Application.get_env(:offloader, :cors_origins)

  @doc """
  DuckDB read-connection pool size (`OFFLOADER_POOL_SIZE`), or nil for the engine
  default. More connections = more concurrent in-flight queries before callers queue.
  """
  @spec pool_size() :: pos_integer() | nil
  def pool_size, do: Application.get_env(:offloader, :pool_size)

  @doc """
  Max entries in the per-snapshot response cache (`OFFLOADER_CACHE_MAX_ENTRIES`),
  default `10_000`. Bounds cache memory so open-cardinality params can't grow it
  without limit; on overflow the oldest entries are evicted.
  """
  @spec cache_max_entries() :: pos_integer()
  def cache_max_entries, do: Application.get_env(:offloader, :cache_max_entries) || 10_000

  @doc """
  Remote object-store credentials parsed from `OFFLOADER_S3_*` / `OFFLOADER_GCS_*`
  env, or nil for local-filesystem mode. Shape documented in `Offloader.ObjectStore`.
  `%{type: "gcs_bearer"}` (from `OFFLOADER_GCS_AUTH=bearer`) reads GCS over HTTPS with
  OAuth bearer tokens resolved at apply time (`Offloader.Gcs.Token` chain).
  """
  @spec object_store() :: map() | nil
  def object_store, do: Application.get_env(:offloader, :object_store)

  @doc "An explicit GCS access token (`OFFLOADER_GCS_TOKEN`), or nil to use the token chain."
  @spec gcs_token() :: String.t() | nil
  def gcs_token, do: Application.get_env(:offloader, :gcs_token)

  @doc """
  True when config reads should be UNAUTHENTICATED (`OFFLOADER_GCS_AUTH=none|anonymous|public`)
  — for loading a project from a PUBLIC `gs://` bucket with no credentials (the zero-setup
  run-box). The GCS client then omits the Authorization header; a 401/403 means the bucket
  isn't actually public and is surfaced, not retried.
  """
  @spec gcs_anonymous?() :: boolean()
  def gcs_anonymous?, do: Application.get_env(:offloader, :gcs_anonymous, false) == true

  @doc """
  DuckDB per-database thread cap (`OFFLOADER_DUCKDB_THREADS`), or nil for the DuckDB
  default (all host cores). Set this in a container: DuckDB sees host cores, not the
  cgroup limit, so with the read pool it can oversubscribe and thrash.
  """
  @spec duckdb_threads() :: pos_integer() | nil
  def duckdb_threads, do: Application.get_env(:offloader, :duckdb_threads)

  @doc "DuckDB memory limit (`OFFLOADER_DUCKDB_MEMORY_LIMIT`, e.g. \"2GB\"), or nil for the default."
  @spec duckdb_memory_limit() :: String.t() | nil
  def duckdb_memory_limit, do: Application.get_env(:offloader, :duckdb_memory_limit)
end
