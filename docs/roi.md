# ROI diagnostic

Before you offload anything, this answers one question: **how much of your warehouse bill is
actually reducible** by moving repeated reads to Offloader — as a number with a confidence
level, not a sales promise. It clusters your repeated bounded reads, maps them to serving
endpoints, and estimates the reducible spend.

## Who runs it, and when

It's the first step of the paid diagnostic — run while you're deciding whether offloading is
even worth it, against your own warehouse's query history. You run it (or we do, from an export
you provide); either way the output is a report you keep and can hand to whoever signs off on
the spend.

## Why it's a local tool, not an online calculator

Because the input is your **private** query history and cost data — the last thing you'd paste
into a public web form. The diagnostic reads a CSV you export from your warehouse, runs entirely
on your machine, and writes a file; none of it leaves your environment. That's the same boundary
as the product itself. A generic web calculator would either guess your numbers (untrustworthy)
or ask you to upload exactly the data you're trying to keep private.

## Run it

```sh
offloader roi report --input examples/roi/sample-query-history.csv \
  --gateway-cost 800 --migration-labor 20000 [--committed-capacity] [--shared-warehouse] \
  --out roi.md
```

## Input format (provider-neutral)

A CSV with one row per query fingerprint (export from Databricks/Snowflake/BigQuery
query history into these columns — provider-specific importers come later):

| column | meaning |
| --- | --- |
| `fingerprint` | a stable id for the repeated query shape |
| `executions_per_month` | how often it runs |
| `avg_cost_usd` | average warehouse cost per execution |
| `warehouse` | the warehouse/cluster it runs on |
| `bounded` | `true` if it's a bounded, repeated shape (offloadable) |
| `candidate_endpoint` | the Offloader endpoint that would serve it (blank = not a candidate) |

## What the report contains

- **Confidence level**, 1–4: **1** the repeated workload is identified (a technical
  candidate, no dollar claim); **2** query logs and cost allocation estimate the reducible
  spend; **3** warehouse size or schedule can actually be reduced; **4** finance verifies
  the bill dropped after offload. Query logs justify **Level 2** at most — the tool will
  not claim more; Levels 3–4 require a live before/after, after you offload.
- **Reducible spend** = bounded, endpoint-mapped queries. Everything else is excluded.
- **Assumptions** (reduction factors, Offloader infra cost, one-time migration labor).
- **Net monthly savings** — conservative / expected / aggressive, minus Offloader cost,
  annualized, with a payback-on-migration-labor figure.
- **Per-endpoint mapping** — which serving endpoint absorbs which spend.
- **Caveats** — see below.

## Honesty (the point of this tool)

- **Committed / flat-rate capacity** (`--committed-capacity`): removing query volume
  does **not** lower the bill until the committed tier or cluster size is actually
  reduced. The tool drops confidence to Level 1–2 and says so — do not promise bill
  reduction.
- **Shared warehouse** (`--shared-warehouse`): the workload isn't the only cost driver,
  so attribution is an estimate — validate against per-query cost allocation.
- All math is explainable and exportable; the report is the artifact, not sales prose.
