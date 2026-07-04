defmodule Offloader.Manifest do
  @moduledoc """
  A Parquet/CSV snapshot manifest and its validator. Pure — no DuckDB. The server
  validates a manifest before materialization so it never serves partial, malformed,
  or unsafe data (`docs/architecture.md` → "Snapshot manifest contract").

  `load/1` validates a manifest in isolation: required fields, snapshot-id format,
  schema (safe names, no duplicates, supported types), file existence, and — for
  local CSV files — that the file's columns match the declared schema.
  `compatibility/2` compares a validated manifest against a dataset contract under
  the manifest's `compatibility_policy`; refresh (G08) uses it to reject a breaking
  producer change while preserving the previous good snapshot.
  """

  alias Offloader.Catalog.{Dataset, Error, Identifier, Parse}

  @enforce_keys [:dataset_id, :snapshot_id, :created_at, :watermark, :schema, :files]
  defstruct [
    :dataset_id,
    :snapshot_id,
    :created_at,
    :watermark,
    :schema,
    :files,
    :partition_columns,
    :sort_columns,
    :row_count,
    :size_bytes,
    :producer,
    :upstream_run_id,
    :schema_version,
    :data_quality_status,
    :compatibility_policy,
    :dir,
    :columns
  ]

  @required ~w(dataset_id snapshot_id created_at watermark schema files partition_columns
               sort_columns row_count size_bytes producer upstream_run_id schema_version
               data_quality_status compatibility_policy)
  # `JSON` marks a nested column (STRUCT/MAP/LIST/JSON) the endpoint serves via to_json.
  @types ~w(DATE TIMESTAMP VARCHAR INTEGER BIGINT DOUBLE BOOLEAN JSON)
  @formats ~w(csv parquet)
  @quality ~w(passed warning failed)
  @policies ~w(additive_only exact)
  @snapshot_re ~r/^[A-Za-z0-9:_.\-]{1,200}$/
  # Numeric widening ladder: a snapshot may be same-or-wider, never narrower.
  @numeric %{"INTEGER" => 1, "BIGINT" => 2, "DOUBLE" => 3}

  @type t :: %__MODULE__{}

  @doc "Read and validate a manifest JSON file. Returns {:ok, manifest} or {:error, errors}."
  @spec load(String.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def load(path) do
    rel = Path.basename(path)

    with {:ok, body} <- read(path, rel),
         {:ok, raw} <- decode(body, rel) do
      validate(raw, Path.dirname(path), rel)
    end
  end

  @doc """
  Check a validated manifest against a dataset contract. `:ok`, or `{:error, errors}`
  listing every breaking change (dropped/renamed column, type narrowing, or — under
  the `exact` policy — an unexpected extra column).
  """
  @spec compatibility(t(), Dataset.t()) :: :ok | {:error, [Error.t()]}
  def compatibility(%__MODULE__{} = manifest, %Dataset{} = dataset) do
    have = Map.new(manifest.schema, &{&1.name, &1.type})
    file = "manifest(#{manifest.snapshot_id})"

    missing_or_narrowed =
      Enum.flat_map(dataset.schema, fn %{name: name, type: want} ->
        case Map.fetch(have, name) do
          :error ->
            [
              Error.new(
                file,
                "schema.#{name}",
                :incompatible_schema,
                "dataset column #{inspect(name)} is missing from the snapshot (dropped or renamed)"
              )
            ]

          {:ok, got} ->
            if compatible?(got, want),
              do: [],
              else: [
                Error.new(
                  file,
                  "schema.#{name}",
                  :incompatible_schema,
                  "column #{inspect(name)}: snapshot type #{got} is not compatible with contract type #{want}",
                  "type narrowing is breaking"
                )
              ]
        end
      end)

    extra =
      if manifest.compatibility_policy == "exact" do
        contract_names = MapSet.new(dataset.schema, & &1.name)

        for %{name: n} <- manifest.schema, not MapSet.member?(contract_names, n) do
          Error.new(
            file,
            "schema.#{n}",
            :incompatible_schema,
            "snapshot has column #{inspect(n)} not in the exact contract"
          )
        end
      else
        []
      end

    case missing_or_narrowed ++ extra do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp compatible?(got, want) do
    cond do
      got == want -> true
      @numeric[got] && @numeric[want] -> @numeric[got] >= @numeric[want]
      true -> false
    end
  end

  # ── validation ────────────────────────────────────────────────────────────────

  defp validate(raw, dir, rel) when is_map(raw) do
    errors =
      missing_fields(raw, rel) ++
        identifier(raw, "dataset_id", rel) ++
        snapshot_id(raw, rel) ++
        timestamp(raw, "created_at", rel) ++
        timestamp(raw, "watermark", rel) ++
        schema_errors(raw, rel) ++
        file_errors(raw, dir, rel) ++
        column_ref(raw, "partition_columns", rel) ++
        column_ref(raw, "sort_columns", rel) ++
        non_neg_int(raw, "row_count", rel) ++
        non_neg_int(raw, "size_bytes", rel) ++
        non_empty(raw, "producer", rel) ++
        non_empty(raw, "upstream_run_id", rel) ++
        pos_int(raw, "schema_version", rel) ++
        member(raw, "data_quality_status", @quality, rel) ++
        member(raw, "compatibility_policy", @policies, rel, :invalid_compatibility_policy)

    if errors == [], do: {:ok, build(raw, dir)}, else: {:error, errors}
  end

  defp validate(_raw, _dir, rel),
    do: {:error, [Error.new(rel, "", :invalid_type, "manifest must be a JSON object")]}

  defp missing_fields(raw, rel) do
    for k <- @required, not Map.has_key?(raw, k) do
      Error.new(rel, k, :missing, "required field #{inspect(k)} is missing")
    end
  end

  defp identifier(raw, key, rel) do
    if Identifier.valid?(raw[key]),
      do: [],
      else: [
        Error.new(
          rel,
          key,
          :unsafe_identifier,
          "#{key} #{inspect(raw[key])} is missing or not a safe identifier"
        )
      ]
  end

  defp snapshot_id(raw, rel) do
    case raw["snapshot_id"] do
      id when is_binary(id) ->
        if Regex.match?(@snapshot_re, id),
          do: [],
          else: [
            Error.new(
              rel,
              "snapshot_id",
              :invalid_snapshot_id,
              "snapshot_id #{inspect(id)} is empty or has invalid characters",
              "use letters, digits, and :_.- only"
            )
          ]

      _ ->
        [Error.new(rel, "snapshot_id", :invalid_snapshot_id, "snapshot_id is required")]
    end
  end

  defp timestamp(raw, key, rel) do
    case raw[key] do
      v when is_binary(v) ->
        case DateTime.from_iso8601(v) do
          {:ok, _dt, _off} ->
            []

          _ ->
            [
              Error.new(
                rel,
                key,
                :invalid_timestamp,
                "#{key} #{inspect(v)} is not an ISO-8601 timestamp"
              )
            ]
        end

      nil ->
        []

      _ ->
        [Error.new(rel, key, :invalid_timestamp, "#{key} must be an ISO-8601 string")]
    end
  end

  defp schema_errors(raw, rel) do
    case raw["schema"] do
      cols when is_list(cols) and cols != [] ->
        names = for c <- cols, is_map(c), is_binary(c["name"]), do: c["name"]

        dup =
          case Parse.duplicates(names) do
            [] ->
              []

            d ->
              [
                Error.new(
                  rel,
                  "schema",
                  :duplicate_column,
                  "duplicate column(s): #{Enum.join(d, ", ")}"
                )
              ]
          end

        per =
          cols
          |> Enum.with_index()
          |> Enum.flat_map(fn {c, i} -> one_column(c, Parse.index("schema", i), rel) end)

        dup ++ per

      _ ->
        [Error.new(rel, "schema", :missing, "schema is required and must be a non-empty list")]
    end
  end

  defp one_column(c, path, rel) when is_map(c) do
    name_err =
      if Identifier.valid_column?(c["name"]),
        do: [],
        else: [
          Error.new(
            rel,
            Parse.join(path, "name"),
            :unsafe_identifier,
            "column name #{inspect(c["name"])} is missing or not a safe identifier"
          )
        ]

    type_err =
      if c["type"] in @types,
        do: [],
        else: [
          Error.new(
            rel,
            Parse.join(path, "type"),
            :unsupported_type,
            "type #{inspect(c["type"])} is not supported",
            "one of: #{Enum.join(@types, ", ")}"
          )
        ]

    name_err ++ type_err
  end

  defp one_column(_c, path, rel),
    do: [Error.new(rel, path, :invalid_type, "schema column must be an object")]

  defp file_errors(raw, dir, rel) do
    case raw["files"] do
      files when is_list(files) and files != [] ->
        files
        |> Enum.with_index()
        |> Enum.flat_map(fn {f, i} ->
          one_file(f, dir, Parse.index("files", i), rel, raw["schema"])
        end)

      _ ->
        [Error.new(rel, "files", :missing, "files is required and must be a non-empty list")]
    end
  end

  defp one_file(f, dir, path, rel, schema) when is_map(f) do
    fmt_err =
      if f["format"] in @formats,
        do: [],
        else: [
          Error.new(
            rel,
            Parse.join(path, "format"),
            :unsupported_type,
            "file format #{inspect(f["format"])} is not supported",
            "one of: #{Enum.join(@formats, ", ")}"
          )
        ]

    case f["path"] do
      p when is_binary(p) and p != "" ->
        fmt_err ++ path_errors(p, dir, f["format"], schema, Parse.join(path, "path"), rel)

      _ ->
        fmt_err ++ [Error.new(rel, Parse.join(path, "path"), :missing, "file path is required")]
    end
  end

  defp one_file(_f, _dir, path, rel, _schema),
    do: [Error.new(rel, path, :invalid_type, "files entry must be an object")]

  # A remote URL (s3://, gs://, https://, …) is trusted here — we can't stat it without
  # network/credentials, and a bad path surfaces as a clear read error at refresh. A
  # local file must exist, and a local CSV's header must match the declared schema.
  defp path_errors(p, dir, format, schema, path, rel) do
    cond do
      Offloader.ObjectStore.remote_path?(p) ->
        []

      File.exists?(Path.expand(p, dir)) ->
        schema_data_errors(Path.expand(p, dir), format, schema, path, rel)

      true ->
        [
          Error.new(
            rel,
            path,
            :missing_file,
            "file #{inspect(p)} does not exist relative to the manifest"
          )
        ]
    end
  end

  # For a local CSV, the header columns must match the declared schema names — a
  # cheap defense against a manifest that describes a different file than it points at.
  defp schema_data_errors(full, "csv", schema, path, rel) when is_list(schema) do
    declared = MapSet.new(for c <- schema, is_map(c), is_binary(c["name"]), do: c["name"])

    case File.open(full, [:read], fn io -> IO.read(io, :line) end) do
      {:ok, line} when is_binary(line) ->
        header = line |> String.trim() |> String.split(",") |> MapSet.new()

        if MapSet.equal?(header, declared),
          do: [],
          else: [
            Error.new(
              rel,
              path,
              :schema_data_mismatch,
              "CSV columns #{inspect(MapSet.to_list(header))} do not match the declared schema #{inspect(MapSet.to_list(declared))}"
            )
          ]

      _ ->
        []
    end
  end

  defp schema_data_errors(_full, _format, _schema, _path, _rel), do: []

  defp column_ref(raw, key, rel) do
    schema_names = MapSet.new(for c <- List.wrap(raw["schema"]), is_map(c), do: c["name"])

    case raw[key] do
      list when is_list(list) ->
        for col <- list, not MapSet.member?(schema_names, col) do
          Error.new(
            rel,
            key,
            :unknown_column,
            "#{key} references #{inspect(col)} which is not in the schema"
          )
        end

      nil ->
        []

      _ ->
        [Error.new(rel, key, :invalid_type, "#{key} must be a list")]
    end
  end

  defp non_neg_int(raw, key, rel) do
    case raw[key] do
      n when is_integer(n) and n >= 0 -> []
      nil -> []
      _ -> [Error.new(rel, key, :invalid_value, "#{key} must be a non-negative integer")]
    end
  end

  defp pos_int(raw, key, rel) do
    case raw[key] do
      n when is_integer(n) and n > 0 -> []
      nil -> []
      _ -> [Error.new(rel, key, :invalid_value, "#{key} must be a positive integer")]
    end
  end

  defp non_empty(raw, key, rel) do
    case raw[key] do
      v when is_binary(v) and v != "" -> []
      nil -> []
      _ -> [Error.new(rel, key, :invalid_value, "#{key} must be a non-empty string")]
    end
  end

  defp member(raw, key, allowed, rel, code \\ :invalid_value) do
    case raw[key] do
      nil ->
        []

      v ->
        if Enum.member?(allowed, v),
          do: [],
          else: [
            Error.new(
              rel,
              key,
              code,
              "#{key} #{inspect(v)} is invalid",
              "one of: #{Enum.join(allowed, ", ")}"
            )
          ]
    end
  end

  defp build(raw, dir) do
    schema = for c <- raw["schema"], do: %{name: c["name"], type: c["type"]}

    %__MODULE__{
      dataset_id: raw["dataset_id"],
      snapshot_id: raw["snapshot_id"],
      created_at: raw["created_at"],
      watermark: raw["watermark"],
      schema: schema,
      files: raw["files"],
      partition_columns: raw["partition_columns"] || [],
      sort_columns: raw["sort_columns"] || [],
      row_count: raw["row_count"],
      size_bytes: raw["size_bytes"],
      producer: raw["producer"],
      upstream_run_id: raw["upstream_run_id"],
      schema_version: raw["schema_version"],
      data_quality_status: raw["data_quality_status"],
      compatibility_policy: raw["compatibility_policy"],
      dir: dir,
      columns: MapSet.new(Enum.map(schema, & &1.name))
    }
  end

  defp read(path, rel) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         [
           Error.new(
             rel,
             "",
             :missing_file,
             "cannot read manifest: #{:file.format_error(reason)}"
           )
         ]}
    end
  end

  defp decode(body, rel) do
    case Jason.decode(body) do
      {:ok, map} ->
        {:ok, map}

      {:error, e} ->
        {:error, [Error.new(rel, "", :invalid_json, "invalid JSON: #{Exception.message(e)}")]}
    end
  end
end
