# ROI diagnostic

The first paid offer is a diagnostic: ingest a customer's query
history, cluster the repeated bounded reads, and estimate the **reducible** warehouse
spend — honestly, with confidence levels, never an inflated bill-reduction promise.

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
