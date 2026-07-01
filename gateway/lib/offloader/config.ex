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

  `"local"` reads manifests and Parquet files from the local filesystem; remote
  source adapters (S3/GCS) are added by later tasks and reuse the same contract.
  """
  @spec object_store_mode() :: String.t()
  def object_store_mode, do: Application.get_env(:offloader, :object_store_mode)
end
