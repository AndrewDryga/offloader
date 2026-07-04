# Examples

Examples let you try Offloader locally in your first hour, and give the docs, tests, and
benchmarks one shared, tiny, deterministic dataset to run against.

## [`customer-analytics/`](customer-analytics/README.md)

A B2B SaaS product-usage dataset with:

- a checked-in 36-row dataset (`customer_usage.csv`) and its approved `manifest.json`
- a dataset contract and three endpoint contracts (summary, daily, top accounts)
- hashed, tenant-bound, endpoint-scoped API key fixtures
- a [failure lab](customer-analytics/failure-lab/README.md): bad manifest, stale
  dataset, unsupported schema change, missing file, bad param, forbidden tenant

Data is CSV by default (no tooling needed); an optional script produces Parquet.
Start at [`customer-analytics/README.md`](customer-analytics/README.md).
