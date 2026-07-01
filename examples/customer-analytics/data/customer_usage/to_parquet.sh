#!/usr/bin/env bash
# Optional: convert the checked-in CSV snapshot to Parquet.
#
# The demo runs on CSV by default (tiny, diffable, no tooling needed). Production
# snapshots are Parquet; use this to produce a Parquet copy for realism or for the
# benchmark harness (B01). Best-effort: uses duckdb if present, else python+pyarrow.
# It does NOT rewrite the manifest — point a manifest's file at the .parquet and set
# "format": "parquet" if you want the gateway to serve it.
set -euo pipefail
cd "$(dirname "$0")"
IN="customer_usage.csv"
OUT="customer_usage.parquet"

if command -v duckdb >/dev/null 2>&1; then
  duckdb -c "COPY (SELECT * FROM read_csv_auto('$IN')) TO '$OUT' (FORMAT parquet);"
  echo "wrote $OUT via duckdb"
elif python3 -c "import pyarrow" >/dev/null 2>&1; then
  python3 - "$IN" "$OUT" <<'PY'
import sys
import pyarrow.csv as pc
import pyarrow.parquet as pq
pq.write_table(pc.read_csv(sys.argv[1]), sys.argv[2])
print(f"wrote {sys.argv[2]} via pyarrow")
PY
else
  echo "neither duckdb nor python pyarrow is available; install one to generate Parquet." >&2
  exit 1
fi
