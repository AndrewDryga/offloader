#!/usr/bin/env bash
# Build the production image and boot it locally against the example config, then
# check health, a real endpoint, and that it runs non-root. Local + container only;
# no cloud. I04's `make deploy-check` reuses this shape for the full rollout check.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${OFFLOADER_IMAGE:-offloader:dev}"
NAME="offloader-smoke-$$"
API_PORT="${API_PORT:-4030}"
ADMIN_PORT="${ADMIN_PORT:-4031}"
CFG="$REPO_ROOT/examples/customer-analytics"
KEY="offl_demo_acme_key"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -f /tmp/csmoke_body_$$; }
trap cleanup EXIT
fail() { echo "container-smoke FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -30 || true; exit 1; }

echo "container-smoke: building $IMAGE"
docker build -t "$IMAGE" -f "$REPO_ROOT/server/Dockerfile" "$REPO_ROOT/server"

echo "container-smoke: running (API :$API_PORT, admin :$ADMIN_PORT)"
docker run -d --name "$NAME" \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e OFFLOADER_ADMIN_TOKEN=smoke-admin \
  -p "127.0.0.1:$API_PORT:4000" -p "127.0.0.1:$ADMIN_PORT:4001" \
  -v "$CFG:/etc/offloader:ro" \
  "$IMAGE" >/dev/null

echo "container-smoke: waiting for readiness"
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ADMIN_PORT/ready" 2>/dev/null || true)" = "200" ] && ready=1 && break
  sleep 1
done
[ "${ready:-0}" = "1" ] || fail "container never became ready"

echo "container-smoke: health + endpoint + non-root"
curl -fsS "http://127.0.0.1:$ADMIN_PORT/live" >/dev/null || fail "/live failed"

code=$(curl -s -o "/tmp/csmoke_body_$$" -w '%{http_code}' -H "Authorization: Bearer $KEY" \
  "http://127.0.0.1:$API_PORT/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01")
[ "$code" = "200" ] || { cat "/tmp/csmoke_body_$$"; fail "endpoint returned $code"; }
jq -e '.meta.snapshot_id and (.data | length >= 1)' "/tmp/csmoke_body_$$" >/dev/null || fail "endpoint body missing snapshot_id/data"

uid="$(docker exec "$NAME" id -u)"
[ "$uid" = "10001" ] || fail "container running as uid $uid, expected non-root 10001"

echo "container-smoke: PASS ($IMAGE boots, serves, non-root)"
