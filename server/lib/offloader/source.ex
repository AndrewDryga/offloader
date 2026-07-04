defmodule Offloader.Source do
  @moduledoc """
  A snapshot source: something that can resolve "the latest consistent snapshot" of a
  dataset into an in-memory `%Offloader.Manifest{}` the engine can materialize.

  The static default (a mounted `manifest.json`) needs no resolver — `Offloader.Manifest.load/1`
  reads it from disk. A dynamic source (e.g. `Offloader.Source.Databricks`) discovers the
  current snapshot remotely on every refresh, so the server follows a producer that
  publishes on its own schedule.

  `{:ok, :none}` means the source is reachable but has no committed snapshot yet — the
  caller keeps serving whatever is active (or stays not-ready).
  """

  alias Offloader.Manifest

  @callback resolve(config :: map()) :: {:ok, Manifest.t()} | {:ok, :none} | {:error, term()}
end

defmodule Offloader.Source.GcsClient do
  @moduledoc """
  The minimal GCS surface a source needs, as a behaviour so resolvers are unit-tested
  with fixture listings and the real HTTP client (credentials and all) stays in one
  place. `list_objects/2` returns maps with at least `"name"` and `"updated"`
  (RFC3339); `get_object/2` returns the object body.
  """

  @callback list_objects(bucket :: String.t(), prefix :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback get_object(bucket :: String.t(), name :: String.t()) ::
              {:ok, binary()} | {:error, term()}
end
