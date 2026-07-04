defmodule Offloader.Docs do
  @moduledoc """
  Generates the endpoint catalog and an OpenAPI spec from the loaded `Catalog`, so
  the docs a product engineer reads always match the contracts the runtime enforces
  (there is no hand-maintained copy to drift). Served on the admin port only.
  """

  alias Offloader.Catalog
  alias Offloader.Catalog.Endpoint

  @base_path "/v1/endpoints"

  @errors [
    %{status: 401, family: "unauthorized", when: "missing, invalid, or revoked API key"},
    %{
      status: 404,
      family: "not_found",
      when: "unknown endpoint, or one your key is not granted (indistinguishable)"
    },
    %{
      status: 422,
      family: "invalid_param",
      when: "a param is missing/mistyped/out of range, or an undeclared param was sent"
    },
    %{status: 503, family: "not_ready", when: "the snapshot is not materialized yet"}
  ]

  @doc "A human-readable, machine-consumable endpoint catalog."
  @spec catalog(Catalog.t()) :: map()
  def catalog(%Catalog{} = cat) do
    %{
      service: "offloader",
      config_version: cat.version,
      auth: auth_summary(cat),
      endpoints:
        cat.endpoints |> Map.values() |> Enum.sort_by(& &1.name) |> Enum.map(&endpoint_doc/1)
    }
  end

  @doc """
  A compact, client-oriented schema of every endpoint: how to call it (params,
  filters, pagination) and what comes back (response columns, flagging nested JSON).
  Leaner than `catalog/1` (no snippets/examples) — the shape a client discovers
  against, akin to an upstream serving API's `/schema` discovery endpoint.
  """
  @spec schema(Catalog.t()) :: map()
  def schema(%Catalog{} = cat) do
    endpoints = cat.endpoints |> Map.values() |> Enum.sort_by(& &1.name)

    %{
      service: "offloader",
      config_version: cat.version,
      auth: auth_summary(cat),
      count: length(endpoints),
      endpoints: Enum.map(endpoints, &schema_entry/1)
    }
  end

  defp auth_summary(%Catalog{auth_mode: "none"}) do
    %{mode: "none", scheme: nil, note: "This API is public: no Authorization header is required."}
  end

  defp auth_summary(%Catalog{}) do
    %{
      mode: "required",
      scheme: "bearer",
      note:
        "Send Authorization: Bearer <api-key>. A key is scoped to specific endpoints and bound to one tenant."
    }
  end

  defp schema_entry(%Endpoint{} = ep) do
    %{
      name: ep.name,
      version: ep.version,
      method: "GET",
      path: "#{@base_path}/#{ep.name}",
      description: ep.description,
      public: ep.tenant_column == nil,
      tenant_scoped: ep.tenant_column != nil,
      params:
        Enum.map(ep.params, fn p ->
          %{
            name: p.name,
            type: p.type,
            required: p.required,
            enum: p.enum,
            default: p.default,
            aliases: p.aliases
          }
        end),
      # [] = any subset of declared params; otherwise the request's param set must
      # exactly match one combination.
      combinations: ep.combinations,
      filters: Enum.map(ep.filters, fn f -> %{column: f.column, op: f.op, param: f.param} end),
      response_columns: Enum.map(ep.select, fn s -> %{name: s.as, nested: s.json?} end),
      column_selection: "columns=<comma-separated subset of response_columns>",
      pagination: %{default_limit: ep.default_limit, max_limit: ep.max_limit}
    }
  end

  @doc "An OpenAPI 3.0 spec describing the product API (served from the admin port)."
  @spec openapi(Catalog.t()) :: map()
  def openapi(%Catalog{} = cat) do
    %{
      openapi: "3.0.3",
      info: %{
        title: "Offloader API",
        version: to_string(cat.version || "1"),
        description:
          "Governed REST endpoints over approved snapshots. Docs are generated from the enforced contracts."
      },
      components: %{securitySchemes: %{bearerAuth: %{type: "http", scheme: "bearer"}}},
      security: [%{bearerAuth: []}],
      paths:
        Map.new(Map.values(cat.endpoints), fn ep ->
          {"#{@base_path}/#{ep.name}", path_item(ep)}
        end)
    }
  end

  # ── catalog entry ──────────────────────────────────────────────────────────────

  defp endpoint_doc(%Endpoint{} = ep) do
    %{
      name: ep.name,
      version: ep.version,
      owner: ep.owner,
      description: ep.description,
      method: "GET",
      path: "#{@base_path}/#{ep.name}",
      auth: %{
        scope: "a key granted #{ep.name}",
        tenant:
          "bound to the API key server-side; it is not a request param and cannot be overridden"
      },
      params: param_docs(ep),
      combinations: ep.combinations,
      pagination: %{default_limit: ep.default_limit, max_limit: ep.max_limit},
      response: %{
        columns: ep.columns,
        snapshot_metadata:
          "meta includes request_id, snapshot_id, generated_at (server time — detect a cached CDN hit), and freshness (watermark, age_seconds, stale)",
        example: example_response(ep)
      },
      freshness_minutes: ep.freshness_minutes,
      errors: @errors,
      snippets: snippets(ep)
    }
  end

  defp param_docs(ep) do
    declared =
      Enum.map(ep.params, fn p ->
        %{
          name: p.name,
          type: p.type,
          required: p.required,
          enum: p.enum,
          default: p.default,
          aliases: p.aliases
        }
      end)

    declared ++
      [
        %{
          name: "limit",
          type: "integer",
          required: false,
          default: ep.default_limit,
          note: "max #{ep.max_limit}"
        },
        %{name: "offset", type: "integer", required: false, default: 0},
        %{
          name: "columns",
          type: "string",
          required: false,
          note: "comma-separated subset of the response columns to return"
        }
      ]
  end

  defp example_response(ep) do
    row = Map.new(ep.columns, fn col -> {col, example_value(col)} end)

    %{
      data: [row],
      meta: %{
        request_id: "b1a2c3d4",
        snapshot_id: "2026-06-01T00:00:00Z_r0007",
        generated_at: "2026-06-01T01:00:00Z",
        row_count: 1,
        freshness: %{watermark: "2026-06-01T00:00:00Z", age_seconds: 3600, stale: false}
      }
    }
  end

  defp example_value(col) do
    cond do
      String.ends_with?(col, "_total") or String.ends_with?(col, "_count") -> 1234
      String.ends_with?(col, "_avg") -> 12.5
      String.contains?(col, "date") -> "2026-06-01"
      String.contains?(col, "id") -> "example_#{col}"
      true -> "example"
    end
  end

  # ── snippets ─────────────────────────────────────────────────────────────────────

  defp snippets(ep) do
    query = example_query(ep)
    path = "#{@base_path}/#{ep.name}#{if query == "", do: "", else: "?" <> query}"

    %{
      curl: ~s(curl -H "Authorization: Bearer $OFFLOADER_KEY" "https://your-host#{path}"),
      typescript: """
      const res = await fetch("https://your-host#{path}", {
        headers: { Authorization: `Bearer ${process.env.OFFLOADER_KEY}` },
      });
      const body = await res.json();
      """,
      python: """
      import os, requests
      r = requests.get(
          "https://your-host#{path}",
          headers={"Authorization": f"Bearer {os.environ['OFFLOADER_KEY']}"},
      )
      body = r.json()
      """
    }
  end

  # A query string of the endpoint's required params with example values.
  defp example_query(ep) do
    ep.params
    |> Enum.filter(& &1.required)
    |> Enum.map_join("&", fn p -> "#{p.name}=#{URI.encode_www_form(example_param(p))}" end)
  end

  defp example_param(%{type: "date"}), do: "2026-05-30"
  defp example_param(%{type: "integer"}), do: "10"
  defp example_param(%{type: "enum", enum: [first | _]}), do: first
  defp example_param(_), do: "example"

  # ── OpenAPI path item ────────────────────────────────────────────────────────────

  defp path_item(%Endpoint{} = ep) do
    %{
      get: %{
        summary: ep.description,
        operationId: ep.name,
        parameters: openapi_params(ep),
        responses: %{
          "200" => %{
            description: "Success",
            content: %{"application/json" => %{schema: response_schema(ep)}}
          },
          "401" => %{description: "Unauthorized"},
          "404" => %{description: "Unknown or unauthorized endpoint"},
          "422" => %{description: "Invalid parameter"}
        }
      }
    }
  end

  defp openapi_params(ep) do
    declared =
      Enum.map(ep.params, fn p ->
        %{name: p.name, in: "query", required: p.required, schema: openapi_schema(p)}
      end)

    declared ++
      [
        %{
          name: "limit",
          in: "query",
          required: false,
          schema: %{type: "integer", maximum: ep.max_limit}
        },
        %{name: "offset", in: "query", required: false, schema: %{type: "integer", minimum: 0}},
        %{
          name: "columns",
          in: "query",
          required: false,
          description: "Comma-separated subset of the response columns to return.",
          schema: %{type: "string"}
        }
      ]
  end

  defp openapi_schema(%{type: "enum", enum: values}), do: %{type: "string", enum: values}
  defp openapi_schema(%{type: "date"}), do: %{type: "string", format: "date"}
  defp openapi_schema(%{type: "integer"}), do: %{type: "integer"}
  defp openapi_schema(_), do: %{type: "string"}

  defp response_schema(ep) do
    props = Map.new(ep.columns, fn col -> {col, %{}} end)

    %{
      type: "object",
      properties: %{
        data: %{type: "array", items: %{type: "object", properties: props}},
        meta: %{type: "object"}
      }
    }
  end
end
