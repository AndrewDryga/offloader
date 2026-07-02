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

  @doc ~S"""
  Object-store access mode (`OFFLOADER_OBJECT_STORE_MODE`), default `"local"`.

  `"local"` reads manifests and Parquet files from the local filesystem. Remote
  snapshots need no mode switch: a manifest file path that is an `s3://`/`gs://`/
  `https://` URL is read directly via DuckDB httpfs, with credentials from
  `object_store/0` (`OFFLOADER_S3_*`). See `Offloader.ObjectStore`.
  """
  @spec object_store_mode() :: String.t()
  def object_store_mode, do: Application.get_env(:offloader, :object_store_mode)

  @doc "Admin token (`OFFLOADER_ADMIN_TOKEN`) gating the admin `/diagnostics` route, or nil."
  @spec admin_token() :: String.t() | nil
  def admin_token, do: Application.get_env(:offloader, :admin_token)

  @doc """
  DuckDB read-connection pool size (`OFFLOADER_POOL_SIZE`), or nil for the engine
  default. More connections = more concurrent in-flight queries before callers queue.
  """
  @spec pool_size() :: pos_integer() | nil
  def pool_size, do: Application.get_env(:offloader, :pool_size)

  @doc """
  Remote object-store credentials parsed from `OFFLOADER_S3_*` / `OFFLOADER_GCS_*`
  env, or nil for local-filesystem mode. Shape documented in `Offloader.ObjectStore`.
  """
  @spec object_store() :: map() | nil
  def object_store, do: Application.get_env(:offloader, :object_store)

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
