# Compare serving modes on the fixture dataset. Run from server/:
#
#     mix run ../dev/scripts/bench-modes.exs
#
# Times the same summary query as (a) local_table (materialized), (b) remote_scan
# (direct file scan), and (c) a response-cache hit. This is a quick relative
# comparison for choosing a serving_mode; B01 builds the full percentile/concurrency
# harness. Numbers are tiny-fixture and machine-relative — do NOT quote them as
# production claims.
alias Offloader.{Catalog, Compiler, Engine, Manifest, Runtime}

dir = Path.expand("../examples/customer-analytics", File.cwd!())
{:ok, cat} = Catalog.load(Path.join(dir, "offloader.yml"))
{:ok, m} = Manifest.load(Path.join(dir, "data/customer_usage/manifest.json"))
ep = cat.endpoints["customer_usage_summary"]
params = %{"from" => "2026-05-30", "to" => "2026-06-01"}
tenant = "tenant_acme"
iterations = 500

cache = Path.join(System.tmp_dir!(), "offl_bench_#{System.unique_integer([:positive])}")
{:ok, eng} = Engine.start_link(cache_dir: cache)
{:ok, _} = Engine.materialize(eng, "snap", m)
:ok = Engine.swap(eng, "customer_usage", "snap")

{:ok, table_plan} = Compiler.compile(ep, params, tenant, {:table, "customer_usage"})
{:ok, scan_plan} = Compiler.compile(ep, params, tenant, {:scan, m.files, m.dir})

time = fn label, fun ->
  # warm up, then time `iterations` runs
  fun.()
  {micros, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> fun.() end) end)
  per = micros / iterations
  IO.puts(:io_lib.format("  ~-14s ~8.1f us/op  (~p ops)", [label, per, iterations]) |> to_string())
  per
end

IO.puts("serving-mode benchmark (#{iterations} iterations, tiny fixture, relative only)\n")
t = time.("local_table", fn -> {:ok, _} = Engine.execute(eng, table_plan.sql, table_plan.params) end)
s = time.("remote_scan", fn -> {:ok, _} = Engine.execute(eng, scan_plan.sql, scan_plan.params) end)
Engine.stop(eng)

{:ok, rt} = Runtime.start_link(name: nil, config_path: Path.join(dir, "offloader.yml"), cache_dir: cache)
{:ok, _} = Runtime.serve(rt, "customer_usage_summary", tenant, params, "warm")
c = time.("cache_hit", fn -> {:ok, _} = Runtime.serve(rt, "customer_usage_summary", tenant, params, "r") end)
GenServer.stop(rt)
File.rm_rf!(cache)

IO.puts("\nrelative to local_table:")
IO.puts("  remote_scan  #{Float.round(s / t, 2)}x")
IO.puts("  cache_hit    #{Float.round(c / t, 2)}x")
