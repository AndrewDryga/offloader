#!/usr/bin/env bash
# Pre-deploy gate: build the PRODUCTION image and boot it locally with a
# production-like env and a temp cache, then verify both ports, the full health
# surface (live/ready/status/metrics/diagnostics), and the manifest -> HTTP smoke
# (happy + denial paths) — so a broken image or config fails here, not in front of a
# customer. Local + container only. Wired into `make deploy-check`. This is also the
# shape a customer wraps in their own post-deploy rollout check.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${OFFLOADER_IMAGE:-offloader:deploy-check}"
NAME="offloader-deploy-check-$$"
API_PORT="${API_PORT:-4050}"
ADMIN_PORT="${ADMIN_PORT:-4051}"
API="http://127.0.0.1:$API_PORT"
ADMIN="http://127.0.0.1:$ADMIN_PORT"
CFG="$REPO_ROOT/examples/customer-analytics"
ADMIN_TOKEN="deploy-check-admin"
KEY="offl_demo_acme_key"
GLOBEX="offl_demo_globex_key"
BODY="$(mktemp)"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -f "$BODY"; }
trap cleanup EXIT
fail() { echo "deploy-check FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -40 || true; exit 1; }

# code <want> <curl-args...>
code() {
  local want="$1"; shift
  local got
  got=$(curl -s -o "$BODY" -w '%{http_code}' "$@")
  [ "$got" = "$want" ] || { echo "  got $got want $want ($*):"; cat "$BODY"; fail "unexpected status"; }
}

echo "deploy-check: building $IMAGE"
docker build -t "$IMAGE" -f "$REPO_ROOT/gateway/Dockerfile" "$REPO_ROOT/gateway"

echo "deploy-check: booting production image (API :$API_PORT, admin :$ADMIN_PORT)"
docker run -d --name "$NAME" \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e OFFLOADER_ADMIN_TOKEN="$ADMIN_TOKEN" \
  -e OFFLOADER_LOG_LEVEL=info \
  -p "127.0.0.1:$API_PORT:4000" -p "127.0.0.1:$ADMIN_PORT:4001" \
  -v "$CFG:/etc/offloader:ro" \
  "$IMAGE" >/dev/null

echo "deploy-check: waiting for readiness"
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$ADMIN/ready" 2>/dev/null || true)" = "200" ] && ready=1 && break
  sleep 1
done
[ "${ready:-0}" = "1" ] || fail "container never became ready"

echo "deploy-check: admin health surface"
code 200 "$ADMIN/live"
code 200 "$ADMIN/ready"
code 200 "$ADMIN/status"
code 200 "$ADMIN/metrics"
grep -q "offloader_up 1" "$BODY" || fail "/metrics missing offloader_up"
code 401 "$ADMIN/diagnostics"                                   # gated
code 200 "$ADMIN/diagnostics" -H "Authorization: Bearer $ADMIN_TOKEN"
jq -e '.duckdb_status == "ok" and (.datasets[0].active_snapshot.snapshot_id | length > 0)' "$BODY" >/dev/null \
  || fail "/diagnostics missing duckdb/snapshot state"

echo "deploy-check: port separation"
code 404 "$API/diagnostics"                                     # admin surface not on API port
code 404 "$API/metrics"

echo "deploy-check: manifest -> HTTP smoke"
for ep in customer_usage_summary customer_usage_daily top_accounts_by_usage; do
  q="from=2026-05-30&to=2026-06-01"
  [ "$ep" = "customer_usage_daily" ] && q="account_id=acct_apollo&$q"
  code 200 -H "Authorization: Bearer $KEY" "$API/v1/endpoints/$ep?$q"
  jq -e '.meta.snapshot_id and (.meta.freshness | has("watermark")) and (.data | length >= 1)' "$BODY" >/dev/null \
    || { cat "$BODY"; fail "$ep missing snapshot/freshness/data"; }
done

echo "deploy-check: denial paths"
code 401 "$API/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01"
code 422 -H "Authorization: Bearer $GLOBEX" "$API/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01&tenant_id=tenant_acme"
code 404 -H "Authorization: Bearer $GLOBEX" "$API/v1/endpoints/customer_usage_daily?account_id=acct_orion&from=2026-05-30&to=2026-06-01"

echo "deploy-check: non-root"
[ "$(docker exec "$NAME" id -u)" = "10001" ] || fail "container is not running non-root"

echo "deploy-check: PASS — $IMAGE is safe to roll out"
