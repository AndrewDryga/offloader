#!/usr/bin/env bash
# End-to-end smoke: manifest -> DuckDB materialization -> HTTP response.
#
# Boots the gateway (via mix) against the customer-analytics example with a temp
# cache, waits until it is ready, calls all three endpoints with a demo API key,
# asserts snapshot_id + freshness metadata, then proves the denial paths fail
# closed. Local ports + temp dirs only; no cloud. Wired into `make e2e`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATEWAY="$REPO_ROOT/gateway"
CONFIG="$REPO_ROOT/examples/customer-analytics/offloader.yml"
API_PORT="${OFFLOADER_API_PORT:-4010}"
ADMIN_PORT="${OFFLOADER_ADMIN_PORT:-4011}"
API="http://127.0.0.1:$API_PORT"
ADMIN="http://127.0.0.1:$ADMIN_PORT"
KEY="offl_demo_acme_key"
GLOBEX="offl_demo_globex_key"

WORK="$(mktemp -d)"
PID=""
fail() { echo "e2e FAIL: $*" >&2; exit 1; }
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  # Free our ports in case the VM outlived its parent (belt-and-suspenders).
  for p in "$API_PORT" "$ADMIN_PORT"; do
    lsof -ti:"$p" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Pre-flight: refuse to run if our ports are busy (actionable, not a confusing timeout).
for p in "$API_PORT" "$ADMIN_PORT"; do
  lsof -ti:"$p" >/dev/null 2>&1 && fail "port $p is in use — free it or set OFFLOADER_API_PORT/OFFLOADER_ADMIN_PORT"
done

echo "e2e: booting gateway on :$API_PORT (admin :$ADMIN_PORT), cache $WORK/cache"
cd "$GATEWAY"
# Run in prod so the env-var container contract (ports, secret) is what's exercised.
export MIX_ENV=prod
mix deps.get >/dev/null
mix compile >/dev/null 2>&1
PHX_SERVER=1 \
  OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  OFFLOADER_CONFIG="$CONFIG" \
  OFFLOADER_CACHE_DIR="$WORK/cache" \
  OFFLOADER_API_PORT="$API_PORT" \
  OFFLOADER_ADMIN_PORT="$ADMIN_PORT" \
  mix run --no-halt >"$WORK/gateway.log" 2>&1 &
PID=$!

# Wait for readiness (admin /ready flips to 200 once the snapshot is materialized).
for _ in $(seq 1 60); do
  kill -0 "$PID" 2>/dev/null || { cat "$WORK/gateway.log"; fail "gateway exited during boot"; }
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$ADMIN/ready" 2>/dev/null || true)" = "200" ]; then
    ready=1
    break
  fi
  sleep 0.5
done
[ "${ready:-0}" = "1" ] || { cat "$WORK/gateway.log"; fail "gateway did not become ready in time"; }

# expect <status> <method-args...> — curls, checks the HTTP code, prints the body path
expect() {
  local want="$1" key="$2" path="$3"
  local code
  code=$(curl -s -o "$WORK/body" -w '%{http_code}' -H "Authorization: Bearer $key" "$API$path")
  [ "$code" = "$want" ] || { echo "  got $code want $want for $path:"; cat "$WORK/body"; fail "unexpected status"; }
}

echo "e2e: happy path — all three endpoints"
for ep in customer_usage_summary customer_usage_daily top_accounts_by_usage; do
  q="from=2026-05-30&to=2026-06-01"
  [ "$ep" = "customer_usage_daily" ] && q="account_id=acct_apollo&$q"
  expect 200 "$KEY" "/v1/endpoints/$ep?$q"
  jq -e '.meta.snapshot_id == "2026-06-01T00:00:00Z_r0007"
         and (.meta.freshness | has("watermark") and has("age_seconds"))
         and (.meta.request_id | length > 0)
         and (.data | length) >= 1' "$WORK/body" >/dev/null \
    || { cat "$WORK/body"; fail "$ep: missing snapshot_id/freshness/data"; }
  echo "  ok  $ep  ($(jq '.data | length' "$WORK/body") rows, snapshot $(jq -r '.meta.snapshot_id' "$WORK/body"))"
done

echo "e2e: denial paths fail closed"
expect 401 "no-such-key" "/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01"
echo "  ok  missing/invalid key -> 401"
# globex smuggles another tenant via a param -> rejected as an unknown param
expect 422 "$GLOBEX" "/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01&tenant_id=tenant_acme"
echo "  ok  tenant override -> 422"
# globex is not granted customer_usage_daily -> 404 (indistinguishable from unknown)
expect 404 "$GLOBEX" "/v1/endpoints/customer_usage_daily?account_id=acct_orion&from=2026-05-30&to=2026-06-01"
echo "  ok  endpoint out of scope -> 404"

echo "e2e: PASS"
