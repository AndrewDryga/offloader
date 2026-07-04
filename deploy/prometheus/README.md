# Prometheus

Offloader exposes Prometheus metrics on the **admin port** at `/metrics` (open for
scraping on the private admin port — no auth, so keep that port internal).

- `scrape.yml` — a `scrape_configs` job for a plain Prometheus.
- `servicemonitor.yaml` — a Prometheus Operator `ServiceMonitor` targeting the
  private admin Service.

Key gauges (see `server/lib/offloader/metrics.ex`): `offloader_up`,
`offloader_ready`, `offloader_duckdb_up`, `offloader_snapshot_age_seconds`,
`offloader_snapshot_stale`, `offloader_refresh_ok`, `offloader_source_reachable`,
`offloader_cache_disk_free_bytes`.

Example alert rules over these metrics — each annotated with the likely owner
(Offloader / customer environment / upstream data) — are in
[`../../docs/operations/alerts.example.yml`](../../docs/operations/alerts.example.yml).
