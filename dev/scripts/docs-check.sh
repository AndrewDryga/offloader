#!/usr/bin/env bash
# Lightweight docs gate: the core docs exist, and no forbidden overclaim appears
# anywhere. V1 sells a narrow, honest product — this catches a stray "SOC2 certified"
# or "99.9% uptime" before it ships. Prose is otherwise reviewed by humans.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0

for f in README.md docs/concepts.md docs/quickstart.md docs/developer-experience.md \
         docs/config-reference.md docs/cli.md docs/api.md docs/public-serving.md \
         docs/security-model.md docs/operator.md docs/deployment.md docs/benchmarks.md \
         docs/architecture.md docs/release.md; do
  [ -f "$f" ] || { echo "docs-check: missing required doc $f" >&2; fail=1; }
done

# Overclaims that must NEVER appear (we make no such promise, even in marketing).
if hits=$(grep -rniE 'soc ?2 (certified|compliant)|99\.9+% ?uptime|\buptime guarantee\b|\bunlimited\b' docs/ README.md 2>/dev/null); then
  echo "docs-check: forbidden overclaim(s) found:" >&2
  echo "$hits" >&2
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "  ok       docs-check: core docs present, no overclaims"
else
  exit 1
fi
