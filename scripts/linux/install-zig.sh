#!/usr/bin/env bash
# Install the pinned Zig into PREFIX, verified against deps/zig/checksums.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
version=$(tr -d '[:space:]' < "$repo/deps/zig/VERSION")
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 64 ;; esac
prefix=${1:?Usage: install-zig.sh PREFIX}
read -r sha url < <(awk -v host="$arch-linux" '$1 == host { print $2, $3 }' "$repo/deps/zig/checksums")
[[ $url == "https://ziglang.org/download/$version/"* && $sha =~ ^[0-9a-f]{64}$ ]] || { echo "No pinned Zig $version checksum for $arch-linux" >&2; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
curl --retry 3 -fsSL "$url" -o "$stage/zig.tar.xz"
printf '%s  %s\n' "$sha" "$stage/zig.tar.xz" | sha256sum -c -
mkdir -p "$prefix"
tar -xJf "$stage/zig.tar.xz" --strip-components=1 -C "$prefix"
[[ $("$prefix/zig" version) == "$version" ]]
