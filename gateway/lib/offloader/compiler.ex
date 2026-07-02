defmodule Offloader.Compiler.Plan do
  @moduledoc """
  A compiled query: parameterized SQL, its bound values, the output columns, and
  which of those columns carry a JSON document (a `to_json(...)` projection) to be
  decoded into a nested term.
  """
  @enforce_keys [:sql, :params, :columns]
  defstruct [:sql, :params, :columns, json_columns: []]

  @type t :: %__MODULE__{
          sql: String.t(),
          params: [term()],
          columns: [String.t()],
          json_columns: [String.t()]
        }
end

defmodule Offloader.Compiler do
  @moduledoc """
  Turns a validated `%Endpoint{}` + a request into a safe parameterized plan. This
  is the whole trust boundary between a consumer and SQL:

    * Only *values* become query params (`$1`, `$2`, …). Every identifier in the
      SQL (columns, table, aggregates) comes from the already-validated endpoint
      contract, never from the request.
    * The tenant filter is `$1`, inserted here from the caller's key-bound tenant.
      It is not derived from any request param and cannot be overridden.
    * Unknown request params are rejected (so a smuggled `tenant_id=` fails with
      `invalid_param`, never silently reaching the query).
    * Pagination is bounded: `limit` is clamped to the endpoint's `max_limit`.

  Errors are `%Offloader.ApiError{}` in the `invalid_param` family.
  """

  alias Offloader.ApiError
  alias Offloader.Catalog.Endpoint
  alias Offloader.Compiler.Plan

  @reserved ~w(limit offset columns)
  @ops %{"eq" => "=", "gte" => ">=", "lte" => "<="}

  @typedoc "Where to read from: a materialized table (local_table) or a direct file scan (remote_scan)."
  @type source :: {:table, String.t()} | {:scan, [map()], String.t()}

  @doc """
  Compile `endpoint` + `request` params (string-keyed) for `tenant`, reading from
  `source`. Returns {:ok, %Plan{}} or {:error, %ApiError{}}.
  """
  @spec compile(Endpoint.t(), map(), String.t() | nil, source()) ::
          {:ok, Plan.t()} | {:error, ApiError.t()}
  def compile(%Endpoint{} = endpoint, request, tenant, source)
      when is_map(request) and (is_binary(tenant) or is_nil(tenant)) do
    with :ok <- reject_unknown(endpoint, request),
         :ok <- check_combination(endpoint, request),
         {:ok, coerced} <- coerce_params(endpoint, request),
         {:ok, projection} <- coerce_columns(endpoint, request),
         {:ok, limit} <- coerce_limit(endpoint, request),
         {:ok, offset} <- coerce_offset(request) do
      {:ok, build(endpoint, coerced, tenant, source, limit, offset, projection)}
    end
  end

  # ── request validation ────────────────────────────────────────────────────────

  defp reject_unknown(endpoint, request) do
    allowed = MapSet.new(Enum.map(endpoint.params, & &1.name) ++ @reserved)

    case Enum.find(Map.keys(request), &(not MapSet.member?(allowed, &1))) do
      nil -> :ok
      key -> {:error, ApiError.new(:invalid_param, "unknown param #{inspect(key)}")}
    end
  end

  # When the endpoint declares combinations, the SET of declared params the client
  # sent (reserved params aside) must exactly match one of them — checked before
  # defaults are merged, mirroring upstream's validate_params semantics.
  defp check_combination(%Endpoint{combinations: []}, _request), do: :ok

  defp check_combination(%Endpoint{combinations: combos}, request) do
    reserved = MapSet.new(@reserved)

    sent =
      request
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(reserved, &1))
      |> MapSet.new()

    if Enum.any?(combos, &MapSet.equal?(MapSet.new(&1), sent)),
      do: :ok,
      else: {:error, ApiError.new(:invalid_param, "params do not match an allowed combination")}
  end

  # The optional reserved `columns` param selects a SUBSET of the endpoint's response
  # columns — it can narrow the projection, never widen it past the allowlist.
  # Returns nil (full projection) or the subset in endpoint select order.
  defp coerce_columns(endpoint, request) do
    case Map.fetch(request, "columns") do
      :error ->
        {:ok, nil}

      {:ok, raw} when is_binary(raw) ->
        requested = raw |> String.split(",") |> Enum.map(&String.trim/1)
        allowed = MapSet.new(endpoint.columns)

        cond do
          requested == [] or Enum.any?(requested, &(&1 == "")) ->
            {:error,
             ApiError.new(:invalid_param, "columns must be a comma-separated list of columns")}

          unknown = Enum.find(requested, &(not MapSet.member?(allowed, &1))) ->
            {:error, ApiError.new(:invalid_param, "unknown column #{inspect(unknown)}")}

          true ->
            keep = MapSet.new(requested)
            {:ok, for(s <- endpoint.select, MapSet.member?(keep, s.as), do: s.as)}
        end

      {:ok, _not_binary} ->
        {:error,
         ApiError.new(:invalid_param, "columns must be a comma-separated list of columns")}
    end
  end

  defp coerce_params(endpoint, request) do
    Enum.reduce_while(endpoint.params, {:ok, %{}}, fn param, {:ok, acc} ->
      case Map.fetch(request, param.name) do
        {:ok, raw} ->
          case coerce(param, raw) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, param.name, value)}}
            {:error, msg} -> {:halt, {:error, ApiError.new(:invalid_param, msg)}}
          end

        :error ->
          cond do
            param.required ->
              {:halt,
               {:error,
                ApiError.new(:invalid_param, "missing required param #{inspect(param.name)}")}}

            # An omitted optional param with a declared default still filters, bound to
            # the default (already validated + coerced at config load).
            not is_nil(param.default) ->
              {:cont, {:ok, Map.put(acc, param.name, param.default)}}

            true ->
              {:cont, {:ok, acc}}
          end
      end
    end)
  end

  defp coerce(%{type: "string", name: name} = param, raw) do
    if is_binary(raw),
      do: {:ok, apply_aliases(param, raw)},
      else: {:error, "param #{inspect(name)} must be a string"}
  end

  defp coerce(%{type: "date", name: name}, raw) do
    case is_binary(raw) and Date.from_iso8601(raw) do
      {:ok, _date} -> {:ok, raw}
      _ -> {:error, "param #{inspect(name)} must be an ISO date (YYYY-MM-DD)"}
    end
  end

  defp coerce(%{type: "integer", name: name} = param, raw) do
    with true <- is_binary(raw),
         {n, ""} <- Integer.parse(raw) do
      cond do
        param.max && n > param.max ->
          {:error, "param #{inspect(name)} exceeds max of #{param.max}"}

        true ->
          {:ok, n}
      end
    else
      _ -> {:error, "param #{inspect(name)} must be an integer"}
    end
  end

  defp coerce(%{type: "enum", name: name, enum: values} = param, raw) when is_binary(raw) do
    value = apply_aliases(param, raw)

    cond do
      Enum.member?(values, value) ->
        {:ok, value}

      (fixed = plus_restored(value)) && Enum.member?(values, fixed) ->
        {:ok, fixed}

      true ->
        {:error, "param #{inspect(name)} is not an allowed value"}
    end
  end

  defp coerce(%{type: "enum", name: name}, _raw),
    do: {:error, "param #{inspect(name)} is not an allowed value"}

  # Map a client value through the param's aliases (value → stored value; an unknown
  # value passes through unchanged). Plug decodes a literal `+` in a query string as a
  # space, and values like "EMERALD+" use `+` literally — so a value with a trailing
  # space that doesn't match is retried with the `+` restored before falling through.
  defp apply_aliases(%{aliases: aliases}, raw) when is_map(aliases) do
    cond do
      Map.has_key?(aliases, raw) ->
        Map.fetch!(aliases, raw)

      (fixed = plus_restored(raw)) && Map.has_key?(aliases, fixed) ->
        Map.fetch!(aliases, fixed)

      true ->
        raw
    end
  end

  defp apply_aliases(_param, raw), do: raw

  defp plus_restored(raw) do
    if String.ends_with?(raw, " "), do: String.trim_trailing(raw) <> "+", else: nil
  end

  defp coerce_limit(endpoint, request) do
    max = endpoint.max_limit || 100
    default = endpoint.default_limit || 50

    case Map.fetch(request, "limit") do
      :error ->
        {:ok, default}

      {:ok, raw} ->
        case Integer.parse(to_string(raw)) do
          {n, ""} when n >= 1 and n <= max ->
            {:ok, n}

          {n, ""} when n > max ->
            {:error, ApiError.new(:invalid_param, "limit exceeds max of #{max}")}

          _ ->
            {:error, ApiError.new(:invalid_param, "limit must be a positive integer")}
        end
    end
  end

  defp coerce_offset(request) do
    case Map.fetch(request, "offset") do
      :error ->
        {:ok, 0}

      {:ok, raw} ->
        case Integer.parse(to_string(raw)) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, ApiError.new(:invalid_param, "offset must be a non-negative integer")}
        end
    end
  end

  # ── SQL assembly (identifiers are all from validated config) ───────────────────

  defp build(endpoint, coerced, tenant, source, limit, offset, projection) do
    selected = selected_items(endpoint, projection)
    projection_sql = Enum.map_join(selected, ", ", &select_sql/1)

    # A tenant endpoint pins the tenant filter to $1 (from the API key, never a
    # request); a public (non-tenant) endpoint has none, and filters start at $1.
    {tenant_sql, tenant_params, first_filter_idx} =
      if endpoint.tenant_column,
        do: {[~s(#{ident(endpoint.tenant_column)} = $1)], [tenant], 2},
        else: {[], [], 1}

    present = for f <- endpoint.filters, Map.has_key?(coerced, f.param), do: f

    {filter_sqls, filter_params} =
      present
      |> Enum.with_index(first_filter_idx)
      |> Enum.reduce({[], []}, fn {f, idx}, {sqls, params} ->
        sql =
          ~s(#{filter_column_sql(endpoint, f)} #{@ops[f.op]} $#{idx}#{param_cast(endpoint, f)})

        {[sql | sqls], [coerced[f.param] | params]}
      end)

    conditions = tenant_sql ++ Enum.reverse(filter_sqls)
    where = if conditions == [], do: "", else: " WHERE " <> Enum.join(conditions, " AND ")
    params = tenant_params ++ Enum.reverse(filter_params)

    limit_idx = length(params) + 1
    offset_idx = limit_idx + 1

    sql =
      "SELECT #{projection_sql} FROM #{from_sql(source)}" <>
        where <>
        group_by_sql(endpoint) <>
        order_by_sql(endpoint, selected) <>
        " LIMIT $#{limit_idx} OFFSET $#{offset_idx}"

    %Plan{
      sql: sql,
      params: params ++ [limit, offset],
      columns: Enum.map(selected, & &1.as),
      json_columns: for(s <- selected, s.json?, do: s.as)
    }
  end

  # (Plan struct is defined at the top of this file so the compiler can expand it.)

  # The select items to project: all of them, or the ?columns= subset (validated in
  # coerce_columns/2), kept in endpoint select order.
  defp selected_items(endpoint, nil), do: endpoint.select

  defp selected_items(endpoint, projection) do
    keep = MapSet.new(projection)
    Enum.filter(endpoint.select, &MapSet.member?(keep, &1.as))
  end

  defp select_sql(s), do: select_expr(s) <> " AS " <> ident(s.as)

  # A JSON (nested) column is projected whole via to_json — cast to VARCHAR so it comes
  # back as a document string the engine decodes into a nested term. Aggregation on a
  # JSON column is rejected at config-load, so `agg` is always nil here.
  defp select_expr(%{column: col, json?: true}), do: "to_json(" <> ident(col) <> ")::VARCHAR"

  defp select_expr(%{column: col, agg: agg}) do
    case agg do
      "sum" -> "sum(#{ident(col)})::BIGINT"
      "count" -> "count(#{ident(col)})::BIGINT"
      "avg" -> "avg(#{ident(col)})::DOUBLE"
      "min" -> "min(#{ident(col)})"
      "max" -> "max(#{ident(col)})"
      nil -> ident(col)
    end
  end

  defp group_by_sql(%Endpoint{group_by: []}), do: ""

  defp group_by_sql(%Endpoint{group_by: names} = endpoint) do
    cols =
      for name <- names, sel = find_select(endpoint, name), do: ident(sel.column)

    " GROUP BY " <> Enum.join(cols, ", ")
  end

  defp order_by_sql(%Endpoint{order_by: []}, _selected), do: ""

  defp order_by_sql(%Endpoint{order_by: orders} = endpoint, selected) do
    selected_as = MapSet.new(selected, & &1.as)

    " ORDER BY " <>
      Enum.map_join(orders, ", ", fn %{column: c, dir: d} ->
        "#{order_ref(endpoint, c, selected_as)} #{dir_sql(d)}"
      end)
  end

  # An order column names a select output; when ?columns= excludes it from the
  # projection, order by the underlying expression instead of the now-missing alias.
  defp order_ref(endpoint, name, selected_as) do
    if MapSet.member?(selected_as, name),
      do: ident(name),
      else: endpoint |> find_select(name) |> select_expr()
  end

  defp dir_sql("desc"), do: "DESC"
  defp dir_sql(_), do: "ASC"

  defp find_select(endpoint, as), do: Enum.find(endpoint.select, &(&1.as == as))

  # A string/enum-param filter compares stringly — CAST(col AS VARCHAR) = $n — so a
  # string value like "ALL" against a non-VARCHAR column filters to no rows instead of
  # erroring (upstream_serving_api semantics; a no-op cast on VARCHAR columns). Date params
  # cast the PARAM side (::DATE); integer params compare natively.
  defp filter_column_sql(endpoint, f) do
    case param_type(endpoint, f.param) do
      t when t in ["string", "enum"] -> "CAST(#{ident(f.column)} AS VARCHAR)"
      _ -> ident(f.column)
    end
  end

  defp param_cast(endpoint, f) do
    if param_type(endpoint, f.param) == "date", do: "::DATE", else: ""
  end

  defp param_type(endpoint, name) do
    Enum.find_value(endpoint.params, fn p -> if p.name == name, do: p.type end)
  end

  # local_table reads a materialized view/table; remote_scan reads the source files
  # directly per request (a subquery). Both come from validated config/manifests.
  defp from_sql({:table, name}), do: ident(name)
  defp from_sql({:scan, files, dir}), do: "(" <> Offloader.Sql.read_files_expr(files, dir) <> ")"

  # DuckDB identifier quoting. Inputs are already safe identifiers (validated by
  # Offloader.Catalog); quoting is defense in depth.
  defp ident(name), do: Offloader.Sql.quote_ident(name)
end
