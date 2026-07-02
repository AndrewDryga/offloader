#!/usr/bin/env bash
# Benchmark harness: cold/warm load, memory, disk, and p50/p95/p99 latency at
# concurrency 1/10/50 against the customer-analytics example. Compares the
# local_table serving path (fresh reads) against response-cache hits.
#
#   ./dev/scripts/benchmark.sh [out_dir]
#
# Env: BENCH_REQUESTS (per scenario, default 300 — short for CI), BENCH_CONCURRENCY
# (default "1 10 50"). Writes summary.json + summary.md and prints the markdown.
#
# Numbers are from a TINY fixture on the local machine and are RELATIVE ONLY — never
# quote them as production latency claims (that's what a real pilot benchmark is for).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$REPO_ROOT/dev/scripts"
GATEWAY="$REPO_ROOT/gateway"
CONFIG="$REPO_ROOT/examples/customer-analytics/offloader.yml"
API_PORT="${OFFLOADER_API_PORT:-4020}"
ADMIN_PORT="${OFFLOADER_ADMIN_PORT:-4021}"
API="http://127.0.0.1:$API_PORT"
ADMIN="http://127.0.0.1:$ADMIN_PORT"
KEY="offl_demo_acme_key"
REQUESTS="${BENCH_REQUESTS:-300}"
CONCURRENCY="${BENCH_CONCURRENCY:-1 10 50}"
OUT_DIR="${1:-$(mktemp -d)}"
mkdir -p "$OUT_DIR"

WORK="$(mktemp -d)"
PID=""
fail() { echo "benchmark FAIL: $*" >&2; exit 1; }
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  for p in "$API_PORT" "$ADMIN_PORT"; do lsof -ti:"$p" 2>/dev/null | xargs -r kill -9 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
for p in "$API_PORT" "$ADMIN_PORT"; do lsof -ti:"$p" >/dev/null 2>&1 && fail "port $p in use"; done

cd "$GATEWAY"
export MIX_ENV=prod
mix deps.get >/dev/null
mix compile >/dev/null 2>&1
SECRET="$(openssl rand -base64 48)"

boot() { # boots the gateway with the shared temp cache; sets PID
  PHX_SERVER=1 OFFLOADER_SECRET_KEY_BASE="$SECRET" OFFLOADER_CONFIG="$CONFIG" \
    OFFLOADER_CACHE_DIR="$WORK/cache" OFFLOADER_API_PORT="$API_PORT" OFFLOADER_ADMIN_PORT="$ADMIN_PORT" \
    mix run --no-halt >"$WORK/gw.log" 2>&1 &
  PID=$!
}
stop() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""; }

echo "benchmark: cold boot (empty cache)"
boot
cold_ms=$(python3 "$SCRIPTS/wait-ready.py" "$ADMIN/ready" 60) || { cat "$WORK/gw.log"; fail "cold boot never ready"; }
echo "  cold_load_ms=$cold_ms"

echo "benchmark: latency sweep ($REQUESTS req/scenario, concurrency: $CONCURRENCY)"
: >"$WORK/scenarios.jsonl"
for scen in "local_table:1" "cache_hit:0"; do
  name="${scen%%:*}"; vary="${scen##*:}"
  for c in $CONCURRENCY; do
    python3 "$SCRIPTS/bench-load.py" "$API" customer_usage_summary "$KEY" "$REQUESTS" "$c" "$vary" \
      | jq --arg n "$name" '. + {scenario: $n}' >>"$WORK/scenarios.jsonl"
    echo "  $name c=$c done"
  done
done

rss_mb=$(( $(ps -o rss= -p "$PID" | tr -d ' ') / 1024 ))
disk_bytes=$(( $(du -sk "$WORK/cache" | cut -f1) * 1024 ))

echo "benchmark: warm restart (existing cache)"
stop
boot
warm_ms=$(python3 "$SCRIPTS/wait-ready.py" "$ADMIN/ready" 60) || { cat "$WORK/gw.log"; fail "warm boot never ready"; }
echo "  warm_load_ms=$warm_ms"
stop

jq -n \
  --arg at "$(date -u +%FT%TZ)" \
  --argjson cold "$cold_ms" --argjson warm "$warm_ms" \
  --argjson rss "$rss_mb" --argjson disk "$disk_bytes" \
  --slurpfile scen "$WORK/scenarios.jsonl" \
  '{generated_at: $at,
    note: "tiny fixture, machine-relative — NOT a production latency claim",
    gateway: {cold_load_ms: $cold, warm_load_ms: $warm, rss_mb: $rss, cache_disk_bytes: $disk},
    scenarios: $scen}' >"$OUT_DIR/summary.json"

{
  echo "# Offloader benchmark"
  echo
  echo "_$(jq -r .note "$OUT_DIR/summary.json")_"
  echo
  echo "Gateway: cold load ${cold_ms}ms · warm load ${warm_ms}ms · RSS ${rss_mb}MB · cache disk $((disk_bytes/1024))KB"
  echo
  echo "| scenario | conc | p50 ms | p95 ms | p99 ms | max ms | rps | errors |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
  jq -r '.scenarios[] | "| \(.scenario) | \(.concurrency) | \(.p50_ms) | \(.p95_ms) | \(.p99_ms) | \(.max_ms) | \(.rps) | \(.errors) |"' "$OUT_DIR/summary.json"
} >"$OUT_DIR/summary.md"

echo
cat "$OUT_DIR/summary.md"
echo
echo "benchmark: wrote $OUT_DIR/summary.json and $OUT_DIR/summary.md"
