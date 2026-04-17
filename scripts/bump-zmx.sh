#!/usr/bin/env bash
# Fetch a zmx release for both macOS arches, lipo to a universal
# binary, and update Resources/zmx-binary/{zmx,VERSION,CHECKSUMS}.
#
# Usage:
#   ./scripts/bump-zmx.sh             # bumps to latest GitHub release
#   ZMX_VERSION=0.5.0 ./scripts/bump-zmx.sh   # pins a specific version
#
# Requires: gh, curl, shasum, lipo, tar.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${ZMX_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    VERSION=$(gh api repos/neurosnap/zmx/releases/latest --jq .tag_name)
fi
VERSION="${VERSION#v}"
echo "→ vendoring zmx ${VERSION}"

mkdir -p Resources/zmx-binary
TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

declare -a checksums
for zmx_arch in aarch64 x86_64; do
    url="https://zmx.sh/a/zmx-${VERSION}-macos-${zmx_arch}.tar.gz"
    echo "  → fetching $url"
    curl -fL --silent --show-error -o "${TMP}/zmx-${zmx_arch}.tar.gz" "$url"
    tar -xzf "${TMP}/zmx-${zmx_arch}.tar.gz" -C "$TMP"
    mv "${TMP}/zmx" "${TMP}/zmx-${zmx_arch}"
    sha=$(shasum -a 256 "${TMP}/zmx-${zmx_arch}" | awk '{print $1}')
    checksums+=("${sha}  zmx-${zmx_arch}")
done

lipo -create "${TMP}/zmx-aarch64" "${TMP}/zmx-x86_64" -output Resources/zmx-binary/zmx
chmod +x Resources/zmx-binary/zmx

uni_sha=$(shasum -a 256 Resources/zmx-binary/zmx | awk '{print $1}')
checksums+=("${uni_sha}  zmx (universal)")

echo "$VERSION" > Resources/zmx-binary/VERSION
printf "%s\n" "${checksums[@]}" > Resources/zmx-binary/CHECKSUMS

echo
echo "✓ vendored zmx ${VERSION}"
echo "  arm64:     ${checksums[0]%% *}"
echo "  x86_64:    ${checksums[1]%% *}"
echo "  universal: ${uni_sha}"
echo "  size:      $(stat -f%z Resources/zmx-binary/zmx) bytes"
echo
echo "Review the diff and commit."
