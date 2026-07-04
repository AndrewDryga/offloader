#!/usr/bin/env bash
# Local, documented release process: build pinned artifacts, an SBOM, a vulnerability
# scan, and checksums into dist/. Best-effort about optional tooling — it uses syft /
# cosign / grype when present and prints exactly what to run when they're absent, so a
# release is reproducible on a laptop or in CI. See docs/release.md.
#
#   ./dev/scripts/release.sh <version>          # e.g. 1.0.0
#   SKIP_IMAGE=1 ./dev/scripts/release.sh 1.0.0 # skip the container image
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo dev)}"
DIST="${DIST:-dist}"
IMAGE="${IMAGE_NAME:-offloader}:$VERSION"
rm -rf "$DIST" && mkdir -p "$DIST"

note() { printf '  %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "release $VERSION -> $DIST/"

# 1. Version-stamped helper binaries — cross-compiled for the install.sh targets.
echo "[1/6] build helper binaries"
for platform in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
  os="${platform%/*}"; arch="${platform#*/}"
  bin="offloader-$VERSION-$os-$arch"
  ( cd tools && GOOS="$os" GOARCH="$arch" \
      go build -trimpath -ldflags "-X main.version=$VERSION" -o "$REPO_ROOT/$DIST/$bin" . )
  note "wrote $bin"
done

# 2. SBOM — syft if available, else the pinned dependency manifests (still an SBOM).
echo "[2/6] SBOM"
if have syft; then
  syft "dir:$REPO_ROOT/tools" -o spdx-json > "$DIST/sbom-tools.spdx.json"
  syft "dir:$REPO_ROOT/gateway" -o spdx-json > "$DIST/sbom-gateway.spdx.json"
  note "syft SBOMs written"
else
  ( cd tools && go list -m all ) > "$DIST/sbom-tools.txt"
  cp gateway/mix.lock "$DIST/sbom-gateway.mix.lock"
  note "syft absent — wrote go module list + pinned mix.lock as the dependency manifest"
fi

# 3. Vulnerability scan.
echo "[3/6] vulnerability scan"
if have govulncheck; then
  ( cd tools && govulncheck ./... ) > "$DIST/govulncheck-tools.txt" 2>&1 || true
  note "govulncheck (Go) -> govulncheck-tools.txt"
else
  note "govulncheck absent — run 'govulncheck ./...' in tools/"
fi
note "Elixir deps: run 'mix deps.audit' (add {:mix_audit, ...} dev/test) and 'mix deps.get' before release"

# 4. Container image (pinned tag) + its digest.
echo "[4/6] container image"
if [ "${SKIP_IMAGE:-0}" != 1 ]; then
  docker build -t "$IMAGE" -f gateway/Dockerfile gateway
  docker image inspect "$IMAGE" --format '{{.Id}}' > "$DIST/image-id.txt"
  note "built $IMAGE ($(cat "$DIST/image-id.txt"))"
  if have grype; then grype "$IMAGE" > "$DIST/grype-image.txt" 2>&1 || true; note "grype image scan -> grype-image.txt"; fi
else
  note "SKIP_IMAGE=1 — skipped the container image"
fi

# 5. Checksums over every artifact.
echo "[5/6] checksums"
( cd "$DIST" && sha256sum -- * > SHA256SUMS 2>/dev/null || shasum -a 256 -- * > SHA256SUMS )
note "SHA256SUMS"

# 6. Signing / attestation.
echo "[6/6] signing"
if have cosign && [ -n "${COSIGN_KEY:-}" ]; then
  cosign sign-blob --key "$COSIGN_KEY" --yes "$DIST/SHA256SUMS" > "$DIST/SHA256SUMS.sig"
  [ "${SKIP_IMAGE:-0}" != 1 ] && cosign sign --key "$COSIGN_KEY" --yes "$IMAGE" || true
  note "cosign-signed SHA256SUMS (+ image)"
else
  note "cosign absent or COSIGN_KEY unset — sign with: cosign sign-blob --key <key> $DIST/SHA256SUMS"
  note "and attest the image: cosign sign --key <key> $IMAGE"
fi

echo
echo "release $VERSION complete. Artifacts in $DIST/:"
( cd "$DIST" && ls -1 )
