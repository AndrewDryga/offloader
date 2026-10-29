defmodule Offloader.ValidationCorpusTest do
  # dev/validation-cases.yml lists broken projects with the exact findings config load must
  # report. tools/validate_corpus_test.go checks `offloader validate` against the same file, so
  # the server and the CLI validator cannot drift apart silently.
  use ExUnit.Case, async: true

  alias Offloader.Catalog

  @corpus Path.expand("../../../dev/validation-cases.yml", __DIR__)
  @external_resource @corpus
  @spec_data YamlElixir.read_from_file!(@corpus)

  # A case's top-level keys replace the base's; a null drops the key. Written as JSON, which
  # every YAML parser reads.
  defp overlay(base, nil), do: JSON.encode!(base)

  defp overlay(base, changes),
    do: base |> Map.merge(changes) |> Map.reject(fn {_k, v} -> is_nil(v) end) |> JSON.encode!()

  defp findings(c) do
    base = @spec_data["base"]
    dir = Path.join(System.tmp_dir!(), "offl_corpus_#{System.unique_integer([:positive])}")
    on_exit(fn -> Offloader.TestSupport.rm_rf!(dir) end)

    files =
      Map.merge(
        %{
          "offloader.yml" => overlay(base["project"], c["project"]),
          "datasets/usage.yml" => overlay(base["dataset"], c["dataset"]),
          "endpoints/e.yml" => overlay(base["endpoint"], c["endpoint"])
        },
        c["files"] || %{}
      )

    for {rel, body} <- files do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    case Catalog.load(Path.join(dir, "offloader.yml")) do
      {:ok, _catalog} -> []
      {:error, errors} -> Enum.map(errors, &[&1.file, &1.path, Atom.to_string(&1.code)])
    end
  end

  for c <- @spec_data["cases"] do
    @case c
    test @case["name"] do
      assert Enum.sort(findings(@case)) == Enum.sort(@case["expect"])
    end
  end
end
