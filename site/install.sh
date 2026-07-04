#!/bin/sh
# Install or update the `offloader` CLI helper (config scaffolding, validation, diagnostics).
#
#   curl -fsSL https://offloader.dryga.com/install.sh | sh
#
# Re-run any time to update to the latest release. Env overrides:
#   OFFLOADER_VERSION   pin a release tag (default: latest, e.g. v1.2.0)
#   OFFLOADER_BIN_DIR   install dir (default: /usr/local/bin if writable, else ~/.local/bin)
#   OFFLOADER_REPO      source repo (default: andrewdryga/offloader)
set -eu

REPO="${OFFLOADER_REPO:-andrewdryga/offloader}"
SRC="git clone https://github.com/$REPO && cd offloader/tools && go build -o offloader ."

die() { echo "offloader: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; exit 1; }

# Prefer curl, fall back to wget — one of them must exist.
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO- "$1"; }
else
  die "need curl or wget to download the release."
fi

# --- platform → GOOS/GOARCH (must match dev/scripts/release.sh asset names) ---
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  linux)  os=linux ;;
  darwin) os=darwin ;;
  *) die "unsupported OS '$os'." "Build from source: $SRC" ;;
esac
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)  arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) die "unsupported architecture '$arch'." "Build from source: $SRC" ;;
esac

# --- resolve the release tag ---
tag="${OFFLOADER_VERSION:-}"
if [ -z "$tag" ]; then
  tag="$(fetch "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1)"
fi
[ -n "$tag" ] || die "no published release found for $REPO." "Build from source: $SRC"

asset="offloader-${tag#v}-$os-$arch"
base="https://github.com/$REPO/releases/download/$tag"

# --- install location ---
dir="${OFFLOADER_BIN_DIR:-}"
if [ -z "$dir" ]; then
  if [ -w /usr/local/bin ]; then dir=/usr/local/bin; else dir="$HOME/.local/bin"; fi
fi
mkdir -p "$dir"

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.sums"' EXIT INT TERM

echo "offloader: downloading $asset ($tag)…"
fetch "$base/$asset" > "$tmp" \
  || die "no prebuilt binary for $os/$arch in release $tag." "Build from source: $SRC"

# --- verify the checksum when SHA256SUMS is published and a hasher is present ---
if fetch "$base/SHA256SUMS" > "$tmp.sums" 2>/dev/null && [ -s "$tmp.sums" ]; then
  want="$(sed -n "s/^\([0-9a-f]\{64\}\)[ *]*$asset\$/\1/p" "$tmp.sums" | head -n1)"
  if [ -n "$want" ]; then
    if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
    else got=""; echo "offloader: no sha256 tool — skipping checksum verification." >&2; fi
    [ -z "$got" ] || [ "$got" = "$want" ] || die "checksum mismatch for $asset — refusing to install."
  fi
fi

chmod +x "$tmp"
mv "$tmp" "$dir/offloader"
trap 'rm -f "$tmp.sums"' EXIT INT TERM

echo "offloader: installed to $dir/offloader"
case ":$PATH:" in
  *":$dir:"*) : ;;
  *) echo "  note: $dir is not on your PATH — add it:  export PATH=\"$dir:\$PATH\"" ;;
esac
"$dir/offloader" version 2>/dev/null || true
