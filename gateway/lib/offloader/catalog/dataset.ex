defmodule Offloader.Catalog.Dataset do
  @moduledoc """
  A dataset contract: the schema the gateway EXPECTS, plus the tenant column and
  where the current manifest lives. This is pure config — no DuckDB, no I/O beyond
  the file it was parsed from. The manifest validator (G03) and refresh (G08) compare
  a shipped snapshot against this contract.
  """

  alias Offloader.Catalog.{Error, Identifier, Parse}

  @enforce_keys [:id, :tenant_column, :schema, :columns]
  defstruct [:id, :description, :manifest, :source, :tenant_column, :schema, :columns]

  @type source :: %{
          type: String.t(),
          bucket: String.t(),
          prefix: String.t(),
          interval_seconds: pos_integer() | nil
        }
  @type column :: %{name: String.t(), type: String.t()}
  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          manifest: String.t() | nil,
          source: source() | nil,
          tenant_column: String.t() | nil,
          schema: [column()],
          columns: MapSet.t()
        }

  @top_keys ~w(id description manifest source tenant_column schema)
  @source_types ~w(databricks)
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
        snapshot_origin_errors(raw, file) ++
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

  # A dataset's snapshots come from exactly ONE origin: a static `manifest` path, or a
  # dynamic `source` that discovers the latest snapshot remotely on each refresh.
  defp snapshot_origin_errors(raw, file) do
    case {raw["manifest"], raw["source"]} do
      {m, nil} when is_binary(m) and m != "" ->
        []

      {nil, %{} = source} ->
        source_errors(source, file)

      {m, %{}} when is_binary(m) ->
        [
          Error.new(
            file,
            "source",
            :conflicting_origin,
            "manifest and source are mutually exclusive",
            "keep the static manifest OR the dynamic source, not both"
          )
        ]

      {nil, nil} ->
        [
          Error.new(
            file,
            "manifest",
            :missing,
            "either a manifest path or a source is required"
          )
        ]

      _ ->
        [Error.new(file, "manifest", :invalid_type, "manifest must be a non-empty string")]
    end
  end

  defp source_errors(source, file) do
    Parse.unknown_keys(source, ~w(type bucket prefix interval_seconds), file, "source") ++
      source_type_errors(source, file) ++
      source_string_errors(source, "bucket", file) ++
      source_string_errors(source, "prefix", file) ++
      source_interval_errors(source, file)
  end

  defp source_type_errors(source, file) do
    case source["type"] do
      t when t in @source_types ->
        []

      t ->
        [
          Error.new(
            file,
            "source.type",
            :invalid_value,
            "source.type #{inspect(t)} is invalid",
            "one of: #{Enum.join(@source_types, ", ")}"
          )
        ]
    end
  end

  defp source_string_errors(source, key, file) do
    case source[key] do
      v when is_binary(v) and v != "" ->
        []

      _ ->
        [
          Error.new(
            file,
            "source.#{key}",
            :missing,
            "source.#{key} is required and must be a non-empty string"
          )
        ]
    end
  end

  defp source_interval_errors(source, file) do
    case source["interval_seconds"] do
      nil ->
        []

      n when is_integer(n) and n > 0 ->
        []

      _ ->
        [
          Error.new(
            file,
            "source.interval_seconds",
            :invalid_value,
            "source.interval_seconds must be a positive integer"
          )
        ]
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
      source: build_source(raw["source"]),
      tenant_column: raw["tenant_column"],
      schema: schema,
      columns: MapSet.new(Enum.map(schema, & &1.name))
    }
  end

  defp build_source(nil), do: nil

  defp build_source(source) do
    %{
      type: source["type"],
      bucket: source["bucket"],
      # the commit-protocol resolver lists under `prefix + "_committed_"`, so the
      # prefix must denote the directory
      prefix: String.trim_trailing(source["prefix"], "/") <> "/",
      interval_seconds: source["interval_seconds"]
    }
  end
end
