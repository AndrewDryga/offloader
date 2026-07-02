defmodule Offloader.Compiler.Plan do
  @moduledoc "A compiled query: parameterized SQL, its bound values, and the output columns."
  @enforce_keys [:sql, :params, :columns]
  defstruct [:sql, :params, :columns]

  @type t :: %__MODULE__{sql: String.t(), params: [term()], columns: [String.t()]}
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

  @reserved ~w(limit offset)
  @ops %{"eq" => "=", "gte" => ">=", "lte" => "<="}

  @typedoc "Where to read from: a materialized table (local_table) or a direct file scan (remote_scan)."
  @type source :: {:table, String.t()} | {:scan, [map()], String.t()}

  @doc """
  Compile `endpoint` + `request` params (string-keyed) for `tenant`, reading from
  `source`. Returns {:ok, %Plan{}} or {:error, %ApiError{}}.
  """
  @spec compile(Endpoint.t(), map(), String.t(), source()) ::
          {:ok, Plan.t()} | {:error, ApiError.t()}
  def compile(%Endpoint{} = endpoint, request, tenant, source)
      when is_map(request) and is_binary(tenant) do
    with :ok <- reject_unknown(endpoint, request),
         {:ok, coerced} <- coerce_params(endpoint, request),
         {:ok, limit} <- coerce_limit(endpoint, request),
         {:ok, offset} <- coerce_offset(request) do
      {:ok, build(endpoint, coerced, tenant, source, limit, offset)}
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

  defp coerce_params(endpoint, request) do
    Enum.reduce_while(endpoint.params, {:ok, %{}}, fn param, {:ok, acc} ->
      case Map.fetch(request, param.name) do
        {:ok, raw} ->
          case coerce(param, raw) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, param.name, value)}}
            {:error, msg} -> {:halt, {:error, ApiError.new(:invalid_param, msg)}}
          end

        :error ->
          if param.required,
            do:
              {:halt,
               {:error,
                ApiError.new(:invalid_param, "missing required param #{inspect(param.name)}")}},
            else: {:cont, {:ok, acc}}
      end
    end)
  end

  defp coerce(%{type: "string", name: name}, raw) do
    if is_binary(raw), do: {:ok, raw}, else: {:error, "param #{inspect(name)} must be a string"}
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

  defp coerce(%{type: "enum", name: name, enum: values}, raw) do
    if Enum.member?(values, raw),
      do: {:ok, raw},
      else: {:error, "param #{inspect(name)} is not an allowed value"}
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

  defp build(endpoint, coerced, tenant, source, limit, offset) do
    projection = Enum.map_join(endpoint.select, ", ", &select_sql/1)

    # WHERE: tenant is always $1; present filters follow as $2, $3, …
    present = for f <- endpoint.filters, Map.has_key?(coerced, f.param), do: f

    {filter_sqls, filter_params} =
      present
      |> Enum.with_index(2)
      |> Enum.reduce({[], []}, fn {f, idx}, {sqls, params} ->
        cast = if date_param?(endpoint, f.param), do: "::DATE", else: ""
        sql = ~s(#{ident(f.column)} #{@ops[f.op]} $#{idx}#{cast})
        {[sql | sqls], [coerced[f.param] | params]}
      end)

    where =
      Enum.join([~s(#{ident(endpoint.tenant_column)} = $1) | Enum.reverse(filter_sqls)], " AND ")

    params = [tenant | Enum.reverse(filter_params)]

    limit_idx = length(params) + 1
    offset_idx = limit_idx + 1

    sql =
      "SELECT #{projection} FROM #{from_sql(source)} WHERE #{where}" <>
        group_by_sql(endpoint) <>
        order_by_sql(endpoint) <>
        " LIMIT $#{limit_idx} OFFSET $#{offset_idx}"

    %Plan{
      sql: sql,
      params: params ++ [limit, offset],
      columns: Enum.map(endpoint.select, & &1.as)
    }
  end

  # (Plan struct is defined at the top of this file so the compiler can expand it.)

  defp select_sql(%{as: as, column: col, agg: agg}) do
    expr =
      case agg do
        "sum" -> "sum(#{ident(col)})::BIGINT"
        "count" -> "count(#{ident(col)})::BIGINT"
        "avg" -> "avg(#{ident(col)})::DOUBLE"
        "min" -> "min(#{ident(col)})"
        "max" -> "max(#{ident(col)})"
        nil -> ident(col)
      end

    ~s(#{expr} AS #{ident(as)})
  end

  defp group_by_sql(%Endpoint{group_by: []}), do: ""

  defp group_by_sql(%Endpoint{group_by: names} = endpoint) do
    cols =
      for name <- names, sel = find_select(endpoint, name), do: ident(sel.column)

    " GROUP BY " <> Enum.join(cols, ", ")
  end

  defp order_by_sql(%Endpoint{order_by: []}), do: ""

  defp order_by_sql(%Endpoint{order_by: orders}) do
    " ORDER BY " <>
      Enum.map_join(orders, ", ", fn %{column: c, dir: d} -> ~s(#{ident(c)} #{dir_sql(d)}) end)
  end

  defp dir_sql("desc"), do: "DESC"
  defp dir_sql(_), do: "ASC"

  defp find_select(endpoint, as), do: Enum.find(endpoint.select, &(&1.as == as))

  defp date_param?(endpoint, name) do
    Enum.any?(endpoint.params, &(&1.name == name and &1.type == "date"))
  end

  # local_table reads a materialized view/table; remote_scan reads the source files
  # directly per request (a subquery). Both come from validated config/manifests.
  defp from_sql({:table, name}), do: ident(name)
  defp from_sql({:scan, files, dir}), do: "(" <> Offloader.Sql.read_files_expr(files, dir) <> ")"

  # DuckDB identifier quoting. Inputs are already safe identifiers (validated by
  # Offloader.Catalog); quoting is defense in depth.
  defp ident(name), do: Offloader.Sql.quote_ident(name)
end
