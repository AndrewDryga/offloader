defmodule Offloader.Catalog do
  @moduledoc """
  The loaded, validated project: datasets, endpoints, and API keys parsed from a
  mounted config directory (`OFFLOADER_CONFIG` points at `offloader.yml`). Pure
  config — no DuckDB, no HTTP. `load/1` returns a fully validated catalog or the
  complete list of errors (every problem at once), so an operator can fix config
  before the server ever serves. Docs (G07) and helper tooling (C02) consume the
  same shape.
  """

  alias Offloader.Catalog.{Dataset, Endpoint, Error, Key, Parse}

  @enforce_keys [:config_dir, :datasets, :endpoints, :keys]
  defstruct [:config_dir, :version, :object_store_mode, :auth_mode, :datasets, :endpoints, :keys]

  @project_keys ~w(version datasets_dir endpoints_dir keys object_store_mode auth)
  @auth_modes ~w(required none)

  @type t :: %__MODULE__{
          config_dir: String.t(),
          object_store_mode: String.t() | nil,
          auth_mode: String.t(),
          datasets: %{optional(String.t()) => Dataset.t()},
          endpoints: %{optional(String.t()) => Endpoint.t()},
          keys: [Key.t()]
        }

  @doc "Load and validate a project from the path to its `offloader.yml`."
  @spec load(String.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def load(project_path) do
    dir = Path.dirname(project_path)

    case read_yaml(project_path, "offloader.yml") do
      {:ok, project} ->
        case Parse.unknown_keys(project, @project_keys, "offloader.yml", "") do
          [] -> load_components(dir, project)
          errors -> {:error, errors}
        end

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp load_components(dir, project) do
    {datasets, dataset_errors} = load_datasets(dir, project["datasets_dir"] || "datasets")

    {endpoints, endpoint_errors} =
      load_endpoints(dir, project["endpoints_dir"] || "endpoints", datasets)

    {keys, key_errors} = load_keys(dir, project["keys"], endpoints)
    {auth_mode, auth_errors} = auth_mode(project, endpoints)

    case dataset_errors ++ endpoint_errors ++ key_errors ++ auth_errors do
      [] ->
        {:ok,
         %__MODULE__{
           config_dir: dir,
           version: project["version"],
           object_store_mode: project["object_store_mode"],
           auth_mode: auth_mode,
           datasets: datasets,
           endpoints: endpoints,
           keys: keys
         }}

      errors ->
        {:error, errors}
    end
  end

  # `auth: required` (default) needs an API key per request; `auth: none` serves the
  # API publicly. Public serving is only safe when NO endpoint is tenant-scoped —
  # otherwise an unauthenticated caller would read across tenants — so that is enforced.
  defp auth_mode(project, endpoints) do
    case project["auth"] do
      nil ->
        {"required", []}

      mode when mode in @auth_modes ->
        {mode, public_tenant_errors(mode, endpoints)}

      other ->
        {"required",
         [
           Error.new(
             "offloader.yml",
             "auth",
             :invalid_value,
             "auth #{inspect(other)} is invalid",
             "one of: #{Enum.join(@auth_modes, ", ")}"
           )
         ]}
    end
  end

  defp public_tenant_errors("none", endpoints) do
    for {name, ep} <- endpoints, ep.tenant_column != nil do
      Error.new(
        "offloader.yml",
        "auth",
        :public_tenant_endpoint,
        "auth: none but endpoint #{inspect(name)} is tenant-scoped",
        "a public API cannot enforce tenancy; serve non-tenant datasets or set auth: required"
      )
    end
  end

  defp public_tenant_errors(_mode, _endpoints), do: []

  # ── datasets ──────────────────────────────────────────────────────────────────

  defp load_datasets(dir, subdir) do
    {parsed, errors} =
      dir
      |> yaml_files(subdir)
      |> Enum.reduce({[], []}, fn {path, rel}, {oks, errs} ->
        case read_yaml(path, rel) do
          {:ok, raw} ->
            case Dataset.parse(raw, rel) do
              {:ok, ds} -> {[ds | oks], errs}
              {:error, e} -> {oks, e ++ errs}
            end

          {:error, e} ->
            {oks, e ++ errs}
        end
      end)

    ids = Enum.map(parsed, & &1.id)
    dup_errors = duplicate_id_errors(ids, "datasets", :duplicate_dataset)
    {Map.new(parsed, &{&1.id, &1}), errors ++ dup_errors}
  end

  # ── endpoints ─────────────────────────────────────────────────────────────────

  defp load_endpoints(dir, subdir, datasets) do
    {parsed, errors} =
      dir
      |> yaml_files(subdir)
      |> Enum.reduce({[], []}, fn {path, rel}, {oks, errs} ->
        case read_yaml(path, rel) do
          {:ok, raw} ->
            case resolve_dataset(raw, datasets, rel) do
              {:ok, ds} ->
                case Endpoint.parse(raw, rel, ds) do
                  {:ok, ep} -> {[ep | oks], errs}
                  {:error, e} -> {oks, e ++ errs}
                end

              {:error, e} ->
                {oks, e ++ errs}
            end

          {:error, e} ->
            {oks, e ++ errs}
        end
      end)

    names = Enum.map(parsed, & &1.name)
    dup_errors = duplicate_id_errors(names, "endpoints", :duplicate_endpoint)
    {Map.new(parsed, &{&1.name, &1}), errors ++ dup_errors}
  end

  # raw is always a map here (read_yaml guarantees it).
  defp resolve_dataset(raw, datasets, rel) do
    case raw["dataset"] do
      id when is_binary(id) ->
        case Map.fetch(datasets, id) do
          {:ok, ds} ->
            {:ok, ds}

          :error ->
            {:error,
             [
               Error.new(
                 rel,
                 "dataset",
                 :unknown_dataset,
                 "endpoint references unknown dataset #{inspect(id)}"
               )
             ]}
        end

      _ ->
        {:error, [Error.new(rel, "dataset", :missing, "dataset is required")]}
    end
  end

  # ── keys ──────────────────────────────────────────────────────────────────────

  defp load_keys(_dir, nil, _endpoints), do: {[], []}

  defp load_keys(dir, keys_rel, endpoints) do
    known = MapSet.new(Map.keys(endpoints))
    path = Path.join(dir, keys_rel)

    case read_yaml(path, keys_rel) do
      {:ok, %{"keys" => list}} when is_list(list) ->
        {parsed, errors} =
          list
          |> Enum.with_index()
          |> Enum.reduce({[], []}, fn {raw, i}, {oks, errs} ->
            case Key.parse(raw, keys_rel, Parse.index("keys", i), known) do
              {:ok, k} -> {[k | oks], errs}
              {:error, e} -> {oks, e ++ errs}
            end
          end)

        dup = duplicate_id_errors(Enum.map(parsed, & &1.id), "keys", :duplicate_key)
        {Enum.reverse(parsed), errors ++ dup}

      {:ok, _} ->
        {[],
         [
           Error.new(
             keys_rel,
             "keys",
             :missing,
             "keys file must contain a top-level `keys:` list"
           )
         ]}

      {:error, e} ->
        {[], e}
    end
  end

  # ── shared helpers ────────────────────────────────────────────────────────────

  defp duplicate_id_errors(ids, path, code) do
    case Parse.duplicates(ids) do
      [] -> []
      dups -> [Error.new(path, path, code, "duplicate name(s): #{Enum.join(dups, ", ")}")]
    end
  end

  # List *.yml/*.yaml under dir/subdir as {absolute_path, relative_path}, sorted.
  defp yaml_files(dir, subdir) do
    full = Path.join(dir, subdir)

    case File.ls(full) do
      {:ok, names} ->
        names
        |> Enum.filter(&(Path.extname(&1) in [".yml", ".yaml"]))
        |> Enum.sort()
        |> Enum.map(&{Path.join(full, &1), Path.join(subdir, &1)})

      {:error, _} ->
        []
    end
  end

  defp read_yaml(path, rel) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error, [Error.new(rel, "", :invalid_type, "file must contain a YAML mapping")]}

      {:error, %{message: msg}} ->
        {:error, [Error.new(rel, "", :yaml_error, "could not parse YAML: #{msg}")]}

      {:error, reason} ->
        {:error, [Error.new(rel, "", :yaml_error, "could not read file: #{inspect(reason)}")]}
    end
  end
end
