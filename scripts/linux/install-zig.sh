#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
version=$(tr -d '[:space:]' < "$repo/scripts/zmx/ZIG_VERSION")
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 64 ;; esac
prefix=${1:?Usage: install-zig.sh PREFIX}
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
curl --retry 3 -fsSL https://ziglang.org/download/index.json -o "$stage/index.json"
read -r url sha < <(python3 - "$stage/index.json" "$version" "$arch" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    release = json.load(source)[sys.argv[2]][f"{sys.argv[3]}-linux"]
print(release["tarball"], release["shasum"])
PY
)
[[ $url == "https://ziglang.org/download/$version/"* && $sha =~ ^[0-9a-f]{64}$ ]] || { echo 'Unexpected Zig download metadata' >&2; exit 1; }
curl --retry 3 -fsSL "$url" -o "$stage/zig.tar.xz"
printf '%s  %s\n' "$sha" "$stage/zig.tar.xz" | sha256sum -c -
mkdir -p "$prefix"
tar -xJf "$stage/zig.tar.xz" --strip-components=1 -C "$prefix"
[[ $("$prefix/zig" version) == "$version" ]]
