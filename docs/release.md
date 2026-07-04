# Release packaging, SBOM, and provenance

Buyers ask for supply-chain basics — pinned artifacts, an SBOM, a vulnerability scan,
signed/attested images, and checksums. This is the release process; run it locally or in CI.
Offloader doesn't claim SOC2 — it ships concrete artifacts instead.

## Run it

```sh
./dev/scripts/release.sh 0.1.4
```

It writes `dist/` with:

| Artifact | What it is |
| --- | --- |
| `offloader-<ver>-<os>-<arch>` | version-stamped helper binaries, one per install target (linux/darwin × amd64/arm64; `-trimpath`, `-X main.version`) — what [`install.sh`](../site/install.sh) downloads. |
| `sbom-tools.*` / `sbom-server.*` | SBOM — syft SPDX if installed, else `go list -m all` + the pinned `mix.lock`. |
| `govulncheck-tools.txt` | Go vulnerability scan output. |
| `image-id.txt` | the built container image digest (tag pinned to `<ver>`). |
| `grype-image.txt` | image vulnerability scan (when grype is installed). |
| `SHA256SUMS` | checksums over every artifact above. |
| `SHA256SUMS.sig` | cosign signature (when cosign + `COSIGN_KEY` are present). |

The script is best-effort about optional tooling: it uses syft / grype / cosign when
present and prints the exact command to run when they're absent, so nothing is silently
skipped.

## Toolchain

| Tool | Purpose | If absent |
| --- | --- | --- |
| `go` / `docker` | build the binary + image | required |
| `sha256sum` | checksums | required (or `shasum -a 256`) |
| `syft` | SPDX SBOM | falls back to dependency manifests |
| `govulncheck` | Go CVE scan | `govulncheck ./...` in `tools/` |
| `mix_audit` | Elixir advisory scan | add `{:mix_audit, "~> 2.1", only: [:dev, :test]}`, run `mix deps.audit` |
| `grype` | image CVE scan | scan the image in CI |
| `cosign` | sign/attest the checksums + image | `cosign sign-blob --key <key> dist/SHA256SUMS` |

## How a buyer verifies

```sh
# integrity
cd dist && sha256sum -c SHA256SUMS
# signature (once signed)
cosign verify-blob --key <pubkey> --signature SHA256SUMS.sig SHA256SUMS
cosign verify --key <pubkey> ghcr.io/andrewdryga/offloader:0.1.4
```

## Publishing

Pin image tags (`ghcr.io/andrewdryga/offloader:0.1.4`, never `:latest`), and publish
`SHA256SUMS` (+ signature) and the SBOM alongside the release so downstream consumers
can verify provenance.
