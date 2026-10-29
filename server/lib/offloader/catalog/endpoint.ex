defmodule Offloader.Catalog.Endpoint do
  @moduledoc """
  An endpoint contract: the public product surface. Pure config/domain — it knows
  params, tenant binding, projection/aggregation, filters, ordering, pagination,
  and cache policy, but NOTHING about SQL or DuckDB. The compiler (G05) turns a
  validated `%Endpoint{}` + request into a safe parameterized plan.

  Validation is strict and collects every error: unknown fields, unsafe
  identifiers, columns that are not in the dataset, projections outside the
  allowlist, filters bound to undeclared params, and an aggregation shape that a
  GROUP BY could not answer are all rejected here.
  """

  alias Offloader.Catalog.{Dataset, Error, Identifier, Parse}
  alias Offloader.Catalog.Endpoint.{Filter, Param, Select}

  @enforce_keys [
    :name,
    :version,
    :owner,
    :dataset,
    :serving_mode,
    :tenant_column,
    :params,
    :columns
  ]
  defstruct [
    :name,
    :version,
    :owner,
    :description,
    :dataset,
    :serving_mode,
    :freshness_minutes,
    :tenant_column,
    :params,
    :combinations,
    :group_by,
    :select,
    :filters,
    :order_by,
    :columns,
    :default_limit,
    :max_limit,
    :cache_policy
  ]

  @top_keys ~w(name version owner description dataset serving_mode freshness tenant params combinations query columns pagination cache)
  @serving_modes ~w(local_table remote_scan)
  @param_types ~w(string integer date enum boolean)
  @aggs ~w(sum avg min max count)
  @ops ~w(eq gte lte)
  @dirs ~w(asc desc)
  @cache_policies ~w(none snapshot)

  @doc """
  Parse and validate an endpoint map against its (already-validated) dataset.
  Returns {:ok, endpoint} or {:error, errors}. Uniqueness across endpoints is
  checked by `Offloader.Catalog`.
  """
  @spec parse(term(), String.t(), Dataset.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(raw, file, %Dataset{} = dataset) when is_map(raw) do
    params = param_list(raw)
    param_names = for p <- params, is_map(p), is_binary(p["name"]), do: p["name"]

    param_types =
      for p <- params, is_map(p), is_binary(p["name"]), into: %{}, do: {p["name"], p["type"]}

    # Read nested shapes defensively: a malformed field is reported below, never crashed on.
    query = if is_map(raw["query"]), do: raw["query"], else: %{}
    selects = if is_list(query["select"]), do: query["select"], else: []
    select_as = for s <- selects, is_map(s), is_binary(s["as"]), do: s["as"]

    errors =
      Parse.unknown_keys(raw, @top_keys, file, "") ++
        identifier_field(raw, "name", file) ++
        required_integer(raw, "version", file) ++
        required_string(raw, "owner", file) ++
        dataset_field(raw, file, dataset) ++
        serving_mode_errors(raw, file) ++
        freshness_errors(raw, file) ++
        tenant_errors(raw, file, dataset) ++
        params_shape_err(raw, file) ++
        param_errors(params, file) ++
        default_range_errors(params, query, dataset, file) ++
        combinations_errors(raw, file, param_names) ++
        query_errors(raw, file, dataset, param_types, select_as) ++
        columns_errors(raw, file, select_as) ++
        pagination_errors(raw, file) ++
        cache_errors(raw, file)

    if errors == [], do: {:ok, build(raw, params, dataset)}, else: {:error, errors}
  end

  def parse(_raw, file, _dataset),
    do: {:error, [Error.new(file, "", :not_a_map, "endpoint config must be a mapping")]}

  # ── scalar fields ────────────────────────────────────────────────────────────

  defp identifier_field(raw, key, file) do
    case raw[key] do
      v when is_binary(v) ->
        if Identifier.valid?(v),
          do: [],
          else: [
            Error.new(
              file,
              key,
              :unsafe_identifier,
              "#{key} #{inspect(v)} is not a safe identifier",
              "lowercase letters, digits, underscores"
            )
          ]

      _ ->
        [Error.new(file, key, :missing, "#{key} is required")]
    end
  end

  defp required_string(raw, key, file) do
    if is_binary(raw[key]) and raw[key] != "",
      do: [],
      else: [Error.new(file, key, :missing, "#{key} is required")]
  end

  defp required_integer(raw, key, file) do
    if is_integer(raw[key]),
      do: [],
      else: [Error.new(file, key, :invalid_type, "#{key} must be an integer")]
  end

  defp dataset_field(raw, file, dataset) do
    case raw["dataset"] do
      id when is_binary(id) ->
        if id == dataset.id,
          do: [],
          else: [
            Error.new(
              file,
              "dataset",
              :unknown_dataset,
              "endpoint references dataset #{inspect(id)} but was validated against #{inspect(dataset.id)}"
            )
          ]

      _ ->
        [Error.new(file, "dataset", :missing, "dataset is required")]
    end
  end

  defp serving_mode_errors(raw, file) do
    case raw["serving_mode"] do
      nil ->
        []

      m when m in @serving_modes ->
        []

      m ->
        [
          Error.new(
            file,
            "serving_mode",
            :invalid_value,
            "serving_mode #{inspect(m)} is invalid",
            "one of: #{Enum.join(@serving_modes, ", ")}"
          )
        ]
    end
  end

  defp freshness_errors(raw, file) do
    case raw["freshness"] do
      nil ->
        []

      %{} = f ->
        Parse.unknown_keys(f, ~w(max_staleness_minutes), file, "freshness") ++
          case f["max_staleness_minutes"] do
            n when is_integer(n) and n > 0 ->
              []

            _ ->
              [
                Error.new(
                  file,
                  "freshness.max_staleness_minutes",
                  :invalid_value,
                  "must be a positive integer"
                )
              ]
          end

      _ ->
        [Error.new(file, "freshness", :invalid_type, "freshness must be a mapping")]
    end
  end

  # The tenant binding must match the dataset: a tenant dataset requires it (fixed to
  # its column, not re-pointable per endpoint); a non-tenant dataset forbids it. This
  # keeps a public dataset from being handed a tenant filter it has no column for.
  defp tenant_errors(raw, file, dataset) do
    case {raw["tenant"], dataset.tenant_column} do
      {%{"column" => col} = t, ds_col} when is_binary(ds_col) ->
        Parse.unknown_keys(t, ~w(column), file, "tenant") ++
          cond do
            not (is_binary(col) and Identifier.valid_column?(col)) ->
              [
                Error.new(
                  file,
                  "tenant.column",
                  :unsafe_identifier,
                  "tenant.column #{inspect(col)} is not a safe identifier"
                )
              ]

            col != ds_col ->
              [
                Error.new(
                  file,
                  "tenant.column",
                  :tenant_mismatch,
                  "tenant.column #{inspect(col)} must equal the dataset tenant_column #{inspect(ds_col)}",
                  "the tenant filter is fixed by the dataset; it cannot be re-pointed per endpoint"
                )
              ]

            true ->
              []
          end

      {nil, ds_col} when is_binary(ds_col) ->
        [
          Error.new(
            file,
            "tenant",
            :missing,
            "tenant binding is required for a tenant dataset",
            "bind #{inspect(ds_col)}, or drop tenant_column from the dataset to serve it publicly"
          )
        ]

      {nil, nil} ->
        []

      {_present, nil} ->
        [
          Error.new(
            file,
            "tenant",
            :tenant_forbidden,
            "dataset #{inspect(dataset.id)} has no tenant_column, so this endpoint cannot bind a tenant",
            "remove the tenant binding, or add tenant_column to the dataset"
          )
        ]

      {_bad, _ds} ->
        [Error.new(file, "tenant", :invalid_type, "tenant must be a mapping with a column")]
    end
  end

  # ── params ───────────────────────────────────────────────────────────────────

  defp param_list(raw), do: (is_list(raw["params"]) && raw["params"]) || []

  defp params_shape_err(%{"params" => params}, file)
       when not is_nil(params) and not is_list(params),
       do: [Error.new(file, "params", :invalid_type, "params must be a list")]

  defp params_shape_err(_raw, _file), do: []

  defp param_errors(params, file) when is_list(params) do
    names = for p <- params, is_map(p), is_binary(p["name"]), do: p["name"]

    dup =
      case Parse.duplicates(names) do
        [] ->
          []

        d ->
          [
            Error.new(
              file,
              "params",
              :duplicate_param,
              "duplicate param name(s): #{Enum.join(d, ", ")}"
            )
          ]
      end

    each =
      params
      |> Enum.with_index()
      |> Enum.flat_map(fn {p, i} -> one_param_errors(p, Parse.index("params", i), file) end)

    dup ++ each
  end

  defp one_param_errors(p, path, file) when is_map(p) do
    Parse.unknown_keys(p, ~w(name type required default enum max aliases), file, path) ++
      name_err(p["name"], path, file) ++
      type_err(p, path, file) ++
      default_err(p, path, file) ++
      aliases_err(p, path, file)
  end

  defp one_param_errors(_p, path, file),
    do: [Error.new(file, path, :invalid_type, "param must be a mapping")]

  # `aliases` maps a CLIENT value to the stored value before the filter binds — a
  # value-level rewrite only, never an identifier. Allowed on string/enum params; for
  # an enum, every alias target must itself be an allowed enum value, so aliasing can
  # never smuggle a value past the enum allowlist.
  defp aliases_err(%{"aliases" => nil}, _path, _file), do: []

  defp aliases_err(%{"aliases" => aliases} = p, path, file) when is_map(aliases) do
    apath = Parse.join(path, "aliases")

    shape_errors =
      for {k, v} <- aliases, not (is_binary(k) and is_binary(v)) do
        Error.new(file, apath, :invalid_type, "alias #{inspect(k)} must map a string to a string")
      end

    type_errors =
      case p["type"] do
        t when t in ["string", "enum"] ->
          []

        t ->
          [
            Error.new(
              file,
              apath,
              :invalid_value,
              "aliases are not supported on #{inspect(t)} params",
              "only string and enum params can declare aliases"
            )
          ]
      end

    enum_errors =
      if p["type"] == "enum" and is_list(p["enum"]) do
        for {k, v} <- aliases, not Enum.member?(p["enum"], v) do
          Error.new(
            file,
            apath,
            :invalid_value,
            "alias #{inspect(k)} maps to #{inspect(v)} which is not an allowed enum value"
          )
        end
      else
        []
      end

    shape_errors ++ type_errors ++ enum_errors
  end

  defp aliases_err(%{"aliases" => _bad}, path, file),
    do: [Error.new(file, Parse.join(path, "aliases"), :invalid_type, "aliases must be a mapping")]

  defp aliases_err(_p, _path, _file), do: []

  # `combinations` restricts which SETS of declared params a request may send (the
  # upstream API's semantics: exact set match, checked before defaults). Each must be a
  # list of declared param names, without duplicates.
  defp combinations_errors(raw, file, param_names) do
    case raw["combinations"] do
      nil ->
        []

      combos when is_list(combos) ->
        combos
        |> Enum.with_index()
        |> Enum.flat_map(fn {combo, i} ->
          one_combination_errors(combo, Parse.index("combinations", i), file, param_names)
        end)

      _ ->
        [
          Error.new(
            file,
            "combinations",
            :invalid_type,
            "combinations must be a list of param-name lists"
          )
        ]
    end
  end

  defp one_combination_errors(combo, path, file, param_names) when is_list(combo) do
    unknown =
      for name <- combo, not Enum.member?(param_names, name) do
        Error.new(
          file,
          path,
          :unknown_param,
          "combination references param #{inspect(name)} which is not declared"
        )
      end

    dup =
      case Parse.duplicates(combo) do
        [] -> []
        d -> [Error.new(file, path, :duplicate_param, "duplicate name(s): #{Enum.join(d, ", ")}")]
      end

    unknown ++ dup
  end

  defp one_combination_errors(_combo, path, file, _param_names),
    do: [Error.new(file, path, :invalid_type, "combination must be a list of param names")]

  # A declared default must satisfy the param's own type, so a bad default is a config
  # error at load — not a runtime surprise when the param is first omitted.
  defp default_err(%{"default" => nil}, _path, _file), do: []

  defp default_err(%{"default" => default} = p, path, file) do
    valid? =
      case p["type"] do
        "string" -> is_binary(default)
        "date" -> is_binary(default) and match?({:ok, _}, Date.from_iso8601(default))
        "integer" -> valid_integer_default?(default, p["max"])
        "enum" -> is_list(p["enum"]) and Enum.member?(p["enum"], default)
        "boolean" -> is_boolean(default)
        _ -> true
      end

    if valid?,
      do: [],
      else: [
        Error.new(
          file,
          Parse.join(path, "default"),
          :invalid_default,
          "default #{inspect(default)} does not satisfy the param's type",
          "the default is used verbatim when the param is omitted"
        )
      ]
  end

  defp default_err(_p, _path, _file), do: []

  # An integer default binds like a request value, so it must fit every column it filters.
  defp default_range_errors(params, query, dataset, file) do
    filters =
      case query["filters"] do
        filters when is_list(filters) -> Enum.filter(filters, &is_map/1)
        _ -> []
      end

    types = Map.new(dataset.schema, &{&1.name, &1.type})

    for {p, i} <- Enum.with_index(params),
        is_map(p) and p["type"] == "integer",
        n = integer_default(p["default"]),
        is_integer(n),
        {lo, hi} = Param.range(for f <- filters, f["param"] == p["name"], do: types[f["column"]]),
        n < lo or n > hi do
      Error.new(
        file,
        Parse.join(Parse.index("params", i), "default"),
        :invalid_default,
        "default #{n} is outside #{lo}..#{hi}, the range of the columns it filters",
        "the default is used verbatim when the param is omitted"
      )
    end
  end

  defp integer_default(n) when is_integer(n), do: n

  defp integer_default(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer_default(_), do: nil

  defp valid_integer_default?(default, max) do
    n =
      cond do
        is_integer(default) -> default
        is_binary(default) -> with({v, ""} <- Integer.parse(default), do: v)
        true -> :error
      end

    is_integer(n) and (is_nil(max) or n <= max)
  end

  defp name_err(name, path, file) do
    if is_binary(name) and Identifier.valid?(name),
      do: [],
      else: [
        Error.new(
          file,
          Parse.join(path, "name"),
          :unsafe_identifier,
          "param name #{inspect(name)} is missing or not a safe identifier"
        )
      ]
  end

  defp type_err(p, path, file) do
    case p["type"] do
      "enum" ->
        if is_list(p["enum"]) and p["enum"] != [],
          do: [],
          else: [
            Error.new(
              file,
              Parse.join(path, "enum"),
              :missing,
              "enum params must list their allowed values"
            )
          ]

      t when t in @param_types ->
        []

      t ->
        [
          Error.new(
            file,
            Parse.join(path, "type"),
            :invalid_value,
            "type #{inspect(t)} is invalid",
            "one of: #{Enum.join(@param_types, ", ")}"
          )
        ]
    end
  end

  # ── query (select / filters / order_by / group_by) ────────────────────────────

  defp query_errors(raw, file, dataset, param_types, select_as) do
    case raw["query"] do
      %{} = q ->
        Parse.unknown_keys(q, ~w(group_by select filters order_by), file, "query") ++
          select_errors(q, file, dataset, select_as) ++
          filter_errors(q, file, dataset, param_types) ++
          order_by_errors(q, file, select_as)

      _ ->
        [Error.new(file, "query", :missing, "query is required")]
    end
  end

  defp select_errors(q, file, dataset, select_as) do
    selects = q["select"]
    group_by = q["group_by"] || []

    cond do
      not (is_list(selects) and selects != []) ->
        [
          Error.new(
            file,
            "query.select",
            :missing,
            "query.select is required and must be a non-empty list"
          )
        ]

      true ->
        dup =
          case Parse.duplicates(select_as) do
            [] ->
              []

            d ->
              [
                Error.new(
                  file,
                  "query.select",
                  :duplicate_column,
                  "duplicate output column(s): #{Enum.join(d, ", ")}"
                )
              ]
          end

        per =
          selects
          |> Enum.with_index()
          |> Enum.flat_map(fn {s, i} ->
            one_select_errors(s, Parse.index("query.select", i), file, dataset)
          end)

        dup ++ per ++ group_by_errors(group_by, selects, select_as, file)
    end
  end

  defp one_select_errors(s, path, file, dataset) when is_map(s) do
    Parse.unknown_keys(s, ~w(as column agg), file, path) ++
      identifier_at(s["as"], Parse.join(path, "as"), file) ++
      column_in_dataset(s["column"], Parse.join(path, "column"), file, dataset) ++
      agg_err(s["agg"], Parse.join(path, "agg"), file) ++
      json_agg_err(s, path, file, dataset)
  end

  defp one_select_errors(_s, path, file, _dataset),
    do: [Error.new(file, path, :invalid_type, "select item must be a mapping")]

  # A JSON (nested) column is served whole via to_json; it cannot be aggregated.
  defp json_agg_err(%{"column" => col, "agg" => agg}, path, file, dataset)
       when not is_nil(agg) do
    if column_type(dataset, col) == "JSON" do
      [
        Error.new(
          file,
          Parse.join(path, "agg"),
          :invalid_agg_on_json,
          "column #{inspect(col)} is JSON (nested) and cannot be aggregated",
          "select it without agg to serve the nested document"
        )
      ]
    else
      []
    end
  end

  defp json_agg_err(_s, _path, _file, _dataset), do: []

  defp column_type(dataset, col),
    do: Enum.find_value(dataset.schema, fn %{name: n, type: t} -> if n == col, do: t end)

  defp agg_err(nil, _path, _file), do: []
  defp agg_err(agg, _path, _file) when agg in @aggs, do: []

  defp agg_err(agg, path, file),
    do: [
      Error.new(
        file,
        path,
        :invalid_value,
        "agg #{inspect(agg)} is invalid",
        "one of: #{Enum.join(@aggs, ", ")}"
      )
    ]

  # In this model, grouping is explicit: if group_by is present every non-aggregated
  # select must be grouped, and every group_by name must be a non-aggregated select.
  # Without group_by, no aggregation is allowed (a plain row projection).
  defp group_by_errors(group_by, _selects, _select_as, file) when not is_list(group_by),
    do: [Error.new(file, "query.group_by", :invalid_type, "group_by must be a list")]

  defp group_by_errors(group_by, selects, select_as, file) do
    non_agg_as = for s <- selects, is_map(s), is_nil(s["agg"]), is_binary(s["as"]), do: s["as"]
    has_agg? = Enum.any?(selects, fn s -> is_map(s) and not is_nil(s["agg"]) end)

    cond do
      group_by == [] and has_agg? ->
        [
          Error.new(
            file,
            "query.group_by",
            :missing_group_by,
            "aggregations require group_by",
            "list the grouping output columns, or remove agg"
          )
        ]

      group_by == [] ->
        []

      true ->
        unknown = for g <- group_by, not Enum.member?(select_as, g), do: g
        not_grouped = non_agg_as -- group_by

        unknown_err =
          if unknown == [],
            do: [],
            else: [
              Error.new(
                file,
                "query.group_by",
                :unknown_column,
                "group_by names not in select: #{Enum.join(unknown, ", ")}"
              )
            ]

        not_grouped_err =
          if not_grouped == [],
            do: [],
            else: [
              Error.new(
                file,
                "query.group_by",
                :ungrouped_column,
                "non-aggregated select columns must be grouped: #{Enum.join(not_grouped, ", ")}"
              )
            ]

        unknown_err ++ not_grouped_err
    end
  end

  defp filter_errors(q, file, dataset, param_types) do
    case q["filters"] do
      nil ->
        []

      filters when is_list(filters) ->
        filters
        |> Enum.with_index()
        |> Enum.flat_map(fn {f, i} ->
          one_filter_errors(f, Parse.index("query.filters", i), file, dataset, param_types)
        end)

      _ ->
        [Error.new(file, "query.filters", :invalid_type, "filters must be a list")]
    end
  end

  defp one_filter_errors(f, path, file, dataset, param_types) when is_map(f) do
    Parse.unknown_keys(f, ~w(column op param), file, path) ++
      column_in_dataset(f["column"], Parse.join(path, "column"), file, dataset) ++
      tenant_filter_err(f["column"], Parse.join(path, "column"), file, dataset) ++
      op_err(f["op"], Parse.join(path, "op"), file) ++
      param_ref_err(f["param"], Parse.join(path, "param"), file, param_types) ++
      filter_type_err(f, Parse.join(path, "param"), file, dataset, param_types) ++
      boolean_op_err(f, Parse.join(path, "op"), file, param_types)
  end

  defp one_filter_errors(_f, path, file, _d, _p),
    do: [Error.new(file, path, :invalid_type, "filter must be a mapping")]

  # The tenant filter is inserted from the API key by the compiler and cannot be a
  # request filter — an endpoint that filters on the tenant column is rejected, so a
  # caller-controlled param can never touch tenant scoping.
  defp tenant_filter_err(col, path, file, dataset) do
    if is_binary(col) and col == dataset.tenant_column,
      do: [
        Error.new(
          file,
          path,
          :tenant_filter_forbidden,
          "filters may not target the tenant column #{inspect(col)}",
          "the tenant filter is inserted from the API key; it cannot be a request filter"
        )
      ],
      else: []
  end

  # duckdbex binds a param by its column's type, so a filter whose param cannot bind fails every
  # request that sends it: a string never binds to BIGINT, and nothing binds a JSON column. The
  # wider data a contract type admits (Manifest.physical_schema/1) binds the same.
  @filterable %{
    "string" => ~w(VARCHAR),
    "enum" => ~w(VARCHAR),
    "integer" => ~w(INTEGER BIGINT DOUBLE),
    "date" => ~w(DATE TIMESTAMP),
    "boolean" => ~w(BOOLEAN)
  }

  defp filter_type_err(%{"column" => col, "param" => param}, path, file, dataset, param_types) do
    with {:ok, fits} <- Map.fetch(@filterable, param_types[param]),
         ctype when is_binary(ctype) <- column_type(dataset, col),
         false <- ctype in fits do
      [
        Error.new(
          file,
          path,
          :incompatible_filter,
          "#{param_types[param]} param #{inspect(param)} cannot filter #{ctype} column #{inspect(col)}",
          filter_hint(ctype)
        )
      ]
    else
      _ -> []
    end
  end

  defp filter_type_err(_f, _path, _file, _dataset, _param_types), do: []

  # Ordering booleans means nothing to a caller, so a boolean param only tests equality. An
  # unknown op is reported by op_err/3 instead.
  defp boolean_op_err(%{"op" => op, "param" => param}, path, file, param_types)
       when op in @ops and op != "eq" do
    if param_types[param] == "boolean",
      do: [
        Error.new(
          file,
          path,
          :incompatible_filter,
          "op #{inspect(op)} cannot compare boolean param #{inspect(param)}",
          "boolean params filter with op: eq"
        )
      ],
      else: []
  end

  defp boolean_op_err(_f, _path, _file, _param_types), do: []

  defp filter_hint(ctype) do
    case for {ptype, fits} <- @filterable, ctype in fits, do: ptype do
      [] -> "#{ctype} columns cannot be filtered"
      ptypes -> "#{ctype} columns take #{Enum.join(ptypes, " or ")} params"
    end
  end

  defp op_err(op, _path, _file) when op in @ops, do: []

  defp op_err(op, path, file),
    do: [
      Error.new(
        file,
        path,
        :invalid_value,
        "op #{inspect(op)} is invalid",
        "one of: #{Enum.join(@ops, ", ")}"
      )
    ]

  defp param_ref_err(param, path, file, param_types) do
    if is_binary(param) and Map.has_key?(param_types, param),
      do: [],
      else: [
        Error.new(
          file,
          path,
          :unknown_param,
          "filter references param #{inspect(param)} which is not declared"
        )
      ]
  end

  defp order_by_errors(q, file, select_as) do
    case q["order_by"] do
      nil ->
        []

      orders when is_list(orders) ->
        orders
        |> Enum.with_index()
        |> Enum.flat_map(fn {o, i} ->
          one_order_errors(o, Parse.index("query.order_by", i), file, select_as)
        end)

      _ ->
        [Error.new(file, "query.order_by", :invalid_type, "order_by must be a list")]
    end
  end

  defp one_order_errors(o, path, file, select_as) when is_map(o) do
    Parse.unknown_keys(o, ~w(column dir), file, path) ++
      order_column_err(o["column"], Parse.join(path, "column"), file, select_as) ++
      dir_err(o["dir"], Parse.join(path, "dir"), file)
  end

  defp one_order_errors(_o, path, file, _s),
    do: [Error.new(file, path, :invalid_type, "order_by item must be a mapping")]

  defp order_column_err(col, path, file, select_as) do
    if is_binary(col) and Enum.member?(select_as, col),
      do: [],
      else: [
        Error.new(
          file,
          path,
          :unknown_column,
          "order_by column #{inspect(col)} must be an output column (a select `as`)"
        )
      ]
  end

  defp dir_err(nil, _path, _file), do: []
  defp dir_err(dir, _path, _file) when dir in @dirs, do: []

  defp dir_err(dir, path, file),
    do: [Error.new(file, path, :invalid_value, "dir #{inspect(dir)} is invalid", "asc or desc")]

  # ── columns allowlist / pagination / cache ────────────────────────────────────

  defp columns_errors(raw, file, select_as) do
    case raw["columns"] do
      cols when is_list(cols) and cols != [] ->
        extra = cols -- select_as
        missing = select_as -- cols

        extra_err =
          if extra == [],
            do: [],
            else: [
              Error.new(
                file,
                "columns",
                :column_not_selected,
                "allowlist columns not produced by select: #{Enum.join(extra, ", ")}"
              )
            ]

        missing_err =
          if missing == [],
            do: [],
            else: [
              Error.new(
                file,
                "columns",
                :column_not_allowlisted,
                "select produces columns missing from the allowlist: #{Enum.join(missing, ", ")}",
                "every response column must be explicitly allowlisted"
              )
            ]

        extra_err ++ missing_err

      _ ->
        [
          Error.new(
            file,
            "columns",
            :missing,
            "columns allowlist is required and must be a non-empty list"
          )
        ]
    end
  end

  defp pagination_errors(raw, file) do
    case raw["pagination"] do
      nil ->
        []

      %{} = p ->
        Parse.unknown_keys(p, ~w(default_limit max_limit), file, "pagination") ++
          limits_err(p["default_limit"], p["max_limit"], file)

      _ ->
        [Error.new(file, "pagination", :invalid_type, "pagination must be a mapping")]
    end
  end

  defp limits_err(default, max, file) do
    cond do
      not (is_integer(default) and default > 0) ->
        [
          Error.new(
            file,
            "pagination.default_limit",
            :invalid_value,
            "must be a positive integer"
          )
        ]

      not (is_integer(max) and max > 0) ->
        [Error.new(file, "pagination.max_limit", :invalid_value, "must be a positive integer")]

      default > max ->
        [
          Error.new(
            file,
            "pagination.default_limit",
            :invalid_value,
            "default_limit #{default} exceeds max_limit #{max}"
          )
        ]

      true ->
        []
    end
  end

  defp cache_errors(raw, file) do
    case raw["cache"] do
      nil ->
        []

      %{"policy" => policy} = c ->
        Parse.unknown_keys(c, ~w(policy), file, "cache") ++
          if policy in @cache_policies,
            do: [],
            else: [
              Error.new(
                file,
                "cache.policy",
                :invalid_value,
                "cache.policy #{inspect(policy)} is invalid",
                "one of: #{Enum.join(@cache_policies, ", ")}"
              )
            ]

      _ ->
        [Error.new(file, "cache", :invalid_type, "cache must be a mapping with a policy")]
    end
  end

  defp column_in_dataset(col, path, file, dataset) do
    cond do
      not (is_binary(col) and Identifier.valid_column?(col)) ->
        [
          Error.new(
            file,
            path,
            :unsafe_identifier,
            "column #{inspect(col)} is missing or not a safe identifier"
          )
        ]

      not MapSet.member?(dataset.columns, col) ->
        [
          Error.new(
            file,
            path,
            :unknown_column,
            "column #{inspect(col)} is not in dataset #{inspect(dataset.id)}"
          )
        ]

      true ->
        []
    end
  end

  # Select `as` names are response keys mirroring source columns (camelCase etc.).
  defp identifier_at(v, path, file) do
    if is_binary(v) and Identifier.valid_column?(v),
      do: [],
      else: [
        Error.new(
          file,
          path,
          :unsafe_identifier,
          "#{path} #{inspect(v)} is missing or not a safe identifier"
        )
      ]
  end

  # ── build (only reached when there are zero errors) ───────────────────────────

  defp build(raw, params, dataset) do
    q = raw["query"]
    types = Map.new(dataset.schema, &{&1.name, &1.type})
    filters = Enum.map(q["filters"] || [], &Filter.build(&1, types[&1["column"]]))

    %__MODULE__{
      name: raw["name"],
      version: raw["version"],
      owner: raw["owner"],
      description: raw["description"],
      dataset: raw["dataset"],
      serving_mode: raw["serving_mode"] || "local_table",
      freshness_minutes: get_in(raw, ["freshness", "max_staleness_minutes"]),
      tenant_column: get_in(raw, ["tenant", "column"]),
      params: Enum.map(params, &Param.build(&1, filters)),
      combinations: raw["combinations"] || [],
      group_by: q["group_by"] || [],
      select: Enum.map(q["select"], fn s -> Select.build(s, types[s["column"]]) end),
      filters: filters,
      order_by: for(o <- q["order_by"] || [], do: %{column: o["column"], dir: o["dir"] || "asc"}),
      columns: raw["columns"],
      default_limit: get_in(raw, ["pagination", "default_limit"]),
      max_limit: get_in(raw, ["pagination", "max_limit"]),
      cache_policy: get_in(raw, ["cache", "policy"]) || "none"
    }
  end

  @type t :: %__MODULE__{}
end

defmodule Offloader.Catalog.Endpoint.Param do
  @moduledoc """
  A declared request parameter. `range` is the `{min, max}` an integer param can bind: the
  range of every column it filters.
  """
  @enforce_keys [:name, :type, :required]
  defstruct [:name, :type, :required, :default, :enum, :max, :aliases, :range]

  @int32 {-2_147_483_648, 2_147_483_647}
  @int64 {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807}

  @doc """
  The values an integer param can bind, given the contract types of the columns it filters:
  32-bit for INTEGER, 64-bit for BIGINT and DOUBLE (what duckdbex binds).
  """
  def range(column_types) do
    Enum.reduce(column_types, @int64, fn
      "INTEGER", {lo, hi} -> {max(lo, elem(@int32, 0)), min(hi, elem(@int32, 1))}
      _type, range -> range
    end)
  end

  @doc """
  An integer param's JSON-schema bounds, `{minimum, maximum}` (nil = none): its configured
  `max`, and its column range when narrower than 64 bits. A 64-bit bound is left out, since a
  JSON client can't represent it exactly.
  """
  def bounds(%__MODULE__{range: range, max: max}) do
    {lo, hi} = if range in [nil, @int64], do: {nil, nil}, else: range
    {lo, Enum.min(Enum.reject([max, hi], &is_nil/1), fn -> nil end)}
  end

  def build(p, filters \\ []) do
    %__MODULE__{
      name: p["name"],
      type: p["type"],
      required: p["required"] == true,
      default: normalize_default(p["type"], p["default"]),
      enum: p["enum"],
      max: p["max"],
      aliases: p["aliases"],
      range:
        if(p["type"] == "integer",
          do: range(for f <- filters, f.param == p["name"], do: f.type)
        )
    }
  end

  # Store the default in its coerced form (validated at parse), so the compiler can
  # bind it directly when the param is omitted.
  defp normalize_default("integer", default) when is_binary(default) do
    {n, ""} = Integer.parse(default)
    n
  end

  defp normalize_default(_type, default), do: default
end

defmodule Offloader.Catalog.Endpoint.Select do
  @moduledoc """
  One output column: `as` (result name) computed from a dataset `column`, optional
  `agg`. `type` is the column's contract type; the compiler casts the output to it so the
  response is typed by the contract. `json?` is set for the logical `JSON` type — the
  compiler then projects it via `to_json(...)` and the response carries a nested term.
  """
  @enforce_keys [:as, :column]
  defstruct [:as, :column, :agg, :type, json?: false]

  def build(s, type \\ nil),
    do: %__MODULE__{
      as: s["as"],
      column: s["column"],
      agg: s["agg"],
      type: type,
      json?: type == "JSON"
    }
end

defmodule Offloader.Catalog.Endpoint.Filter do
  @moduledoc """
  A param-bound filter: `column op :param`. The compiler parameterizes the value. `type` is the
  column's contract type.
  """
  @enforce_keys [:column, :op, :param]
  defstruct [:column, :op, :param, :type]

  def build(f, type \\ nil),
    do: %__MODULE__{column: f["column"], op: f["op"], param: f["param"], type: type}
end
