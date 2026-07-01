defmodule Offloader.Catalog.Error do
  @moduledoc """
  A stable, operator-readable config-validation error. Every error carries the
  file it came from, the field path inside that file, a machine-stable `code`, a
  human message, and an optional hint — so an operator (and the helper tooling in
  C02) can fix config without reading source. Codes are part of the contract:
  don't rename one without updating the docs and tooling that match on it.
  """

  @enforce_keys [:file, :path, :code, :message]
  defstruct [:file, :path, :code, :message, :hint]

  @type t :: %__MODULE__{
          file: String.t(),
          path: String.t(),
          code: atom(),
          message: String.t(),
          hint: String.t() | nil
        }

  @spec new(String.t(), String.t(), atom(), String.t(), String.t() | nil) :: t()
  def new(file, path, code, message, hint \\ nil) do
    %__MODULE__{file: file, path: path, code: code, message: message, hint: hint}
  end

  @doc "One operator-readable line: `file: path: message (code) — hint: ...`."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = e) do
    base = "#{e.file}: #{e.path}: #{e.message} (#{e.code})"
    if e.hint, do: base <> " — hint: " <> e.hint, else: base
  end
end
