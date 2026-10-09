#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
version=${1:?Usage: package.sh VERSION [OUTPUT_DIRECTORY]}
output=${2:-$repo/dist}
[[ $version =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || { echo 'Invalid version' >&2; exit 64; }
[[ $(uname -s) == Linux ]] || { echo 'Linux packaging must run on Linux' >&2; exit 1; }
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 64 ;; esac
cd "$repo"
build_jobs=${GRAFTTY_LINUX_BUILD_JOBS:-4}
[[ $build_jobs =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build job count' >&2; exit 64; }
# Local builds use the serialized wrapper. CI uses its disposable build tree.
if [[ ${CI:-} == true ]]; then
    build_command=(swift)
else
    cache_root=${GRAFTTY_SWIFTPM_SHARED_DIR:-${HOME:?HOME must identify the shared cache}/Library/Caches/Graftty/SwiftPM}
    [[ $cache_root == /* ]] || { echo 'Shared SwiftPM cache path must be absolute' >&2; exit 64; }
    mkdir -p "$cache_root"
    exec 9>"$cache_root/build.lock"
    flock 9
    build_command=(scripts/swiftpm --graftty-swiftpm-lock-held)
fi
"${build_command[@]}" build --jobs "$build_jobs" -c release --product graftty-host
"${build_command[@]}" build --jobs "$build_jobs" -c release --product graftty-cli
binary_dir=$("${build_command[@]}" build --jobs "$build_jobs" -c release --show-bin-path)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
name="graftty-linux-$version-$arch"
bundle="$stage/$name"
mkdir -p "$bundle/bin" "$bundle/lib" "$bundle/libexec" "$bundle/share"
install -m 755 "$binary_dir/graftty-host" "$bundle/libexec/graftty-host"
install -m 755 "$binary_dir/graftty-cli" "$bundle/libexec/graftty-cli"
for resource in "$binary_dir"/*.resources "$binary_dir"/*.bundle; do
    [[ ! -d $resource ]] || cp -a "$resource" "$bundle/libexec/"
done
if [[ ${CI:-} != true ]]; then
    # Another worktree can replace the shared tree only after every build
    # artifact needed by this archive has been copied to private staging.
    flock -u 9
    exec 9>&-
fi
# Host agent hooks resolve a sibling CLI; route through its runtime launcher.
ln -s ../bin/graftty "$bundle/libexec/graftty"
for command in graftty graftty-host; do
    install -m 755 "$repo/scripts/linux/launcher.sh" "$bundle/bin/$command"
done
"$repo/scripts/linux/build-zmx.sh" "$arch" "$bundle/bin/zmx"
python3 "$repo/scripts/linux/bundle-libraries.py" "$bundle/lib" "$bundle/libexec/graftty-host" "$bundle/libexec/graftty-cli"
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
