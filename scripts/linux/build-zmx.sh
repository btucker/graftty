#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
arch=${1:-$(uname -m)}
output=${2:?Usage: build-zmx.sh ARCH OUTPUT}
case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 64 ;; esac
expected_zig=$(tr -d '[:space:]' < "$repo/scripts/zmx/ZIG_VERSION")
[[ $(zig version) == "$expected_zig" ]] || { echo "Zig $expected_zig is required" >&2; exit 1; }
commit=$(tr -d '[:space:]' < "$repo/scripts/zmx/UPSTREAM_COMMIT")
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid zmx revision' >&2; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
git clone --quiet https://github.com/neurosnap/zmx.git "$stage/source"
git -C "$stage/source" checkout --quiet "$commit"
for patch in graftty.patch paging.patch; do
    git -C "$stage/source" apply --check "$repo/scripts/zmx/$patch"
    git -C "$stage/source" apply "$repo/scripts/zmx/$patch"
done
version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",$/\1/p' "$stage/source/build.zig.zon")
[[ -n $version ]] || { echo 'Missing zmx version' >&2; exit 1; }
zig_build_with_download_retry() {
    local attempt status
    for attempt in 1 2 3; do
        if zig "$@" 2>&1 | tee "$stage/zig-build.log" >&2; then
            return 0
        else
            status=${PIPESTATUS[0]}
        fi
        # Only failed dependency transfers are retryable. Compiler errors,
        # test failures, and checksum mismatches retain their original status.
        [[ $status -ne 0 ]] || return 1
        if [[ $attempt -eq 3 ]] || ! grep -Eq '^.*\.zon:[0-9]+:[0-9]+: error: HTTP response read failure: (ConnectionResetByPeer|ConnectionTimedOut|TemporaryNameServerFailure)[[:space:]]*$' "$stage/zig-build.log"; then
            return "$status"
        fi
        echo "Retrying Zig dependency download after attempt $attempt/3" >&2
        sleep "$((attempt * 2))"
    done
}
(
    cd "$stage/source"
    zig fmt --check src
    # Use musl so zmx itself does not need a particular glibc version.
    # Exercise the shipped safety mode. Unoptimized terminal validation makes
    # the 100,000-row history fixtures prohibitively slow on development hosts.
    zig_build_with_download_retry build test -j2 "-Dtarget=$arch-linux-musl" -Doptimize=ReleaseSafe
    zig_build_with_download_retry build -j2 "-Dtarget=$arch-linux-musl" -Doptimize=ReleaseSafe \
        "-Dversion=$version-g${commit:0:7}-graftty7" --prefix "$stage/install"
)
mkdir -p "$(dirname "$output")"
install -m 755 "$stage/install/bin/zmx" "$output"
