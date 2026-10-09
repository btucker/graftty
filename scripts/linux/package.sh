#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
version=${1:?Usage: package.sh VERSION [OUTPUT_DIRECTORY]}
output=${2:-$repo/dist}
[[ $version =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo 'Invalid version' >&2; exit 64; }
[[ $(uname -s) == Linux ]] || { echo 'Linux packaging must run on Linux' >&2; exit 1; }
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 64 ;; esac
cd "$repo"
# Local builds use the serialized wrapper. CI uses its disposable build tree.
if [[ ${CI:-} == true ]]; then
    swift build -c release --product graftty-host
    swift build -c release --product graftty-cli
    binary_dir=$(swift build -c release --show-bin-path)
else
    scripts/swiftpm build -c release --product graftty-host
    scripts/swiftpm build -c release --product graftty-cli
    binary_dir=$(scripts/swiftpm build -c release --show-bin-path)
fi
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
name="graftty-linux-$version-$arch"
bundle="$stage/$name"
mkdir -p "$bundle/bin" "$bundle/lib" "$bundle/libexec" "$bundle/share"
install -m 755 "$binary_dir/graftty-host" "$bundle/libexec/graftty-host"
install -m 755 "$binary_dir/graftty-cli" "$bundle/libexec/graftty-cli"
# Host agent hooks resolve a sibling CLI; route through its runtime launcher.
ln -s ../bin/graftty "$bundle/libexec/graftty"
for command in graftty graftty-host; do
    install -m 755 "$repo/scripts/linux/launcher.sh" "$bundle/bin/$command"
done
"$repo/scripts/linux/build-zmx.sh" "$arch" "$bundle/bin/zmx"
python3 "$repo/scripts/linux/bundle-libraries.py" "$bundle/lib" "$bundle/libexec/graftty-host" "$bundle/libexec/graftty-cli"
for resource in "$binary_dir"/*.resources "$binary_dir"/*.bundle; do
    [[ ! -d $resource ]] || cp -a "$resource" "$bundle/libexec/"
done
cp -a "$repo/Sources/GrafttyKit/GhosttyResources/ghostty" "$bundle/share/ghostty"
cp -a "$repo/Sources/GrafttyKit/GhosttyResources/terminfo" "$bundle/share/terminfo"
printf '%s\n' "$version" > "$bundle/VERSION"
cp "$repo/scripts/zmx/UPSTREAM_COMMIT" "$bundle/share/ZMX_UPSTREAM_COMMIT"
install -m 755 "$repo/scripts/linux/install.sh" "$bundle/install.sh"
cp "$repo/LICENSE" "$bundle/LICENSE"
# Run the packaged launchers before publishing an archive.
"$bundle/bin/graftty-host" --help >/dev/null
"$bundle/bin/graftty" --help >/dev/null
"$bundle/bin/zmx" version
mkdir -p "$output"
output=$(cd "$output" && pwd)
tar -czf "$output/$name.tar.gz" -C "$bundle" .
(cd "$output" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
printf '%s\n' "$output/$name.tar.gz"
