defmodule Offloader.Catalog.Dataset do
  @moduledoc """
  A dataset contract: the schema the gateway EXPECTS, plus the tenant column and
  where the current manifest lives. This is pure config — no DuckDB, no I/O beyond
  the file it was parsed from. The manifest validator (G03) and refresh (G08) compare
  a shipped snapshot against this contract.
  """

  alias Offloader.Catalog.{Error, Identifier, Parse}

  @enforce_keys [:id, :manifest, :tenant_column, :schema, :columns]
  defstruct [:id, :description, :manifest, :tenant_column, :schema, :columns]

  @type column :: %{name: String.t(), type: String.t()}
  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          manifest: String.t(),
          tenant_column: String.t() | nil,
          schema: [column()],
          columns: MapSet.t()
        }

  @top_keys ~w(id description manifest tenant_column schema)
  # DuckDB types V1 supports in a serving dataset. Kept deliberately small. `JSON` is
  # a logical type for a nested column (STRUCT/MAP/LIST/JSON in the snapshot): the
  # endpoint serves it via `to_json(...)`, so the response carries a nested object
  # instead of a flattened value.
  @types ~w(DATE TIMESTAMP VARCHAR INTEGER BIGINT DOUBLE BOOLEAN JSON)

  @doc "Parse and validate a dataset map. Returns {:ok, dataset} or {:error, errors}."
  @spec parse(term(), String.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(raw, file) when is_map(raw) do
    errors =
      Parse.unknown_keys(raw, @top_keys, file, "") ++
        id_errors(raw, file) ++
        required_string(raw, "manifest", file) ++
        tenant_errors(raw, file) ++
        schema_errors(raw, file)

    if errors == [], do: {:ok, build(raw)}, else: {:error, errors}
  end

  def parse(_not_map, file),
    do: {:error, [Error.new(file, "", :not_a_map, "dataset config must be a mapping")]}

  defp id_errors(raw, file) do
    case raw["id"] do
      id when is_binary(id) ->
        if Identifier.valid?(id),
          do: [],
          else: [
            Error.new(
              file,
              "id",
              :unsafe_identifier,
              "dataset id #{inspect(id)} is not a safe identifier",
              "use lowercase letters, digits, underscores"
            )
          ]

      _ ->
        [Error.new(file, "id", :missing, "dataset id is required")]
    end
  end

  defp required_string(raw, key, file) do
    case raw[key] do
      v when is_binary(v) and v != "" -> []
      _ -> [Error.new(file, key, :missing, "#{key} is required and must be a non-empty string")]
    end
  end

  # `tenant_column` is optional: a dataset without one is non-tenant (public) and its
  # endpoints serve unfiltered. When present it must name a real schema column, so the
  # compiler-inserted tenant filter can never point at a column that isn't there.
  defp tenant_errors(raw, file) do
    schema_names = schema_names(raw)

    case raw["tenant_column"] do
      col when is_binary(col) ->
        cond do
          not Identifier.valid?(col) ->
            [
              Error.new(
                file,
                "tenant_column",
                :unsafe_identifier,
                "tenant_column #{inspect(col)} is not a safe identifier"
              )
            ]

          not Enum.member?(schema_names, col) ->
            [
              Error.new(
                file,
                "tenant_column",
                :unknown_column,
                "tenant_column #{inspect(col)} is not in the schema",
                "it must name a column declared in schema"
              )
            ]

          true ->
            []
        end

      nil ->
        []

      _ ->
        [Error.new(file, "tenant_column", :invalid_type, "tenant_column must be a string")]
    end
  end

  defp schema_errors(raw, file) do
    case raw["schema"] do
      cols when is_list(cols) and cols != [] ->
        column_errors(cols, file) ++ duplicate_errors(cols, file)

      _ ->
        [Error.new(file, "schema", :missing, "schema is required and must be a non-empty list")]
    end
  end

  defp column_errors(cols, file) do
    cols
    |> Enum.with_index()
    |> Enum.flat_map(fn {col, i} ->
      path = Parse.index("schema", i)

      name_err =
        if is_map(col) and Identifier.valid?(col["name"]),
          do: [],
          else: [
            Error.new(
              file,
              Parse.join(path, "name"),
              :unsafe_identifier,
              "column name #{inspect(is_map(col) && col["name"])} is missing or not a safe identifier"
            )
          ]

      type_err =
        if is_map(col) and col["type"] in @types,
          do: [],
          else: [
            Error.new(
              file,
              Parse.join(path, "type"),
              :unsupported_type,
              "type #{inspect(is_map(col) && col["type"])} is not supported",
              "one of: #{Enum.join(@types, ", ")}"
            )
          ]

      name_err ++ type_err
    end)
  end

  defp duplicate_errors(cols, file) do
    case Parse.duplicates(schema_names(%{"schema" => cols})) do
      [] ->
        []

      dups ->
        [
          Error.new(
            file,
            "schema",
            :duplicate_column,
            "duplicate column(s): #{Enum.join(dups, ", ")}"
          )
        ]
    end
  end

  defp schema_names(raw) do
    case raw["schema"] do
      cols when is_list(cols) -> for c <- cols, is_map(c), is_binary(c["name"]), do: c["name"]
      _ -> []
    end
  end

  defp build(raw) do
    schema = for c <- raw["schema"], do: %{name: c["name"], type: c["type"]}

    %__MODULE__{
      id: raw["id"],
      description: raw["description"],
      manifest: raw["manifest"],
      tenant_column: raw["tenant_column"],
      schema: schema,
      columns: MapSet.new(Enum.map(schema, & &1.name))
    }
  end
end
