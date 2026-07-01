defmodule Offloader.RefreshTest do
  use ExUnit.Case, async: false

  alias Offloader.Runtime

  @dir Path.expand("../../../examples/customer-analytics", __DIR__)
  @project Path.join(@dir, "offloader.yml")
  @csv Path.join(@dir, "data/customer_usage/customer_usage.csv")
  @fl Path.join(@dir, "failure-lab")
  @good_snapshot "2026-06-01T00:00:00Z_r0007"

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_refresh_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: nil, config_path: @project, cache_dir: dir)

    on_exit(fn ->
      if Process.alive?(rt), do: GenServer.stop(rt)
      File.rm_rf!(dir)
    end)

    %{rt: rt}
  end

  defp served_snapshot(rt) do
    {:ok, resp} =
      Runtime.serve(
        rt,
        "customer_usage_summary",
        "tenant_acme",
        %{"from" => "2026-05-30", "to" => "2026-06-01"},
        "r"
      )

    resp.meta.snapshot_id
  end

  # A second, well-formed manifest with a different snapshot id, pointing at the real CSV.
  defp second_manifest do
    base = Jason.decode!(File.read!(Path.join(@dir, "data/customer_usage/manifest.json")))

    manifest =
      base
      |> Map.put("snapshot_id", "2026-06-05T00:00:00Z_r0099")
      |> Map.put("watermark", "2026-06-05T00:00:00Z")
      |> Map.put("files", [
        %{"path" => @csv, "format" => "csv", "row_count" => 36, "size_bytes" => 2433}
      ])

    write_tmp("manifest.json", Jason.encode!(manifest))
  end

  # A manifest that passes validation (parquet skips the CSV header check) but fails to
  # materialize, because the referenced "parquet" file is garbage.
  defp broken_materialize_manifest do
    root = tmp_root()
    File.mkdir_p!(root)
    File.write!(Path.join(root, "data.parquet"), "not a parquet file")
    base = Jason.decode!(File.read!(Path.join(@dir, "data/customer_usage/manifest.json")))

    manifest =
      base
      |> Map.put("snapshot_id", "2026-06-06T00:00:00Z_r0100")
      |> Map.put("files", [
        %{"path" => "data.parquet", "format" => "parquet", "row_count" => 36, "size_bytes" => 1}
      ])

    path = Path.join(root, "manifest.json")
    File.write!(path, Jason.encode!(manifest))
    on_exit(fn -> File.rm_rf!(root) end)
    path
  end

  test "boots with a good active snapshot and an :ok last attempt", %{rt: rt} do
    assert served_snapshot(rt) == @good_snapshot
    state = Runtime.snapshot_state(rt, "customer_usage")
    assert state.active.snapshot_id == @good_snapshot
    assert state.last_attempted.status == :ok
  end

  test "a failed VALIDATION leaves the active snapshot serving", %{rt: rt} do
    assert {:error, :rejected} =
             Runtime.refresh(rt, "customer_usage", Path.join(@fl, "missing-file/manifest.json"))

    # still serving the previous good snapshot
    assert served_snapshot(rt) == @good_snapshot
    state = Runtime.snapshot_state(rt, "customer_usage")
    assert state.active.snapshot_id == @good_snapshot
    assert state.last_attempted.status == :rejected
    assert is_binary(state.last_attempted.error)
  end

  test "a breaking (incompatible) manifest is rejected without swapping", %{rt: rt} do
    assert {:error, :rejected} =
             Runtime.refresh(
               rt,
               "customer_usage",
               Path.join(@fl, "unsupported-schema-change/manifest.json")
             )

    assert served_snapshot(rt) == @good_snapshot
    assert Runtime.snapshot_state(rt, "customer_usage").last_attempted.status == :rejected
  end

  test "a failed MATERIALIZATION leaves the active snapshot serving", %{rt: rt} do
    assert {:error, :failed} =
             Runtime.refresh(rt, "customer_usage", broken_materialize_manifest())

    assert served_snapshot(rt) == @good_snapshot
    assert Runtime.snapshot_state(rt, "customer_usage").last_attempted.status == :failed
  end

  test "a good refresh swaps atomically and retains the previous for rollback", %{rt: rt} do
    assert {:ok, "2026-06-05T00:00:00Z_r0099"} =
             Runtime.refresh(rt, "customer_usage", second_manifest())

    assert served_snapshot(rt) == "2026-06-05T00:00:00Z_r0099"

    state = Runtime.snapshot_state(rt, "customer_usage")
    assert state.active.snapshot_id == "2026-06-05T00:00:00Z_r0099"
    assert state.previous.snapshot_id == @good_snapshot

    # rollback reverts to the previous good snapshot
    assert {:ok, @good_snapshot} = Runtime.rollback(rt, "customer_usage")
    assert served_snapshot(rt) == @good_snapshot
  end

  test "rollback with no previous snapshot is an error", %{rt: rt} do
    assert {:error, :no_previous} = Runtime.rollback(rt, "customer_usage")
  end

  # ── helpers ────────────────────────────────────────────────────────────────────

  defp tmp_root,
    do: Path.join(System.tmp_dir!(), "offl_man_#{System.unique_integer([:positive])}")

  defp write_tmp(name, body) do
    root = tmp_root()
    File.mkdir_p!(root)
    path = Path.join(root, name)
    File.write!(path, body)
    on_exit(fn -> File.rm_rf!(root) end)
    path
  end
end
