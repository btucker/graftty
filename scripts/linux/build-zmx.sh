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
patches=(graftty.patch paging.patch always-run-tests.patch)
preparing=''
transient_stage=''
cleanup() {
    [[ -z $preparing ]] || rm -rf -- "$preparing"
    [[ -z $transient_stage ]] || rm -rf -- "$transient_stage"
}
trap cleanup EXIT
if [[ -n ${GRAFTTY_ZMX_CACHE_DIR:-} ]]; then
    [[ $GRAFTTY_ZMX_CACHE_DIR == /* ]] || { echo 'Zmx cache path must be absolute' >&2; exit 64; }
    fingerprint=$(python3 - "$repo" "$arch" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256(sys.argv[2].encode())
for name in ('linux/build-zmx.sh', 'zmx/ZIG_VERSION', 'zmx/UPSTREAM_COMMIT',
             'zmx/graftty.patch', 'zmx/paging.patch', 'zmx/always-run-tests.patch'):
    digest.update((root / 'scripts' / name).read_bytes())
print(digest.hexdigest())
PY
)
    mkdir -p "$GRAFTTY_ZMX_CACHE_DIR"
    stage="$GRAFTTY_ZMX_CACHE_DIR/$fingerprint"
    # A stable source path lets Zig reuse compiled modules. Serialize callers
    # sharing this opt-in cache, including preparation and the final copy.
    exec 9>"$stage.lock"
    flock 9
    mkdir -p "$stage"
    export ZIG_GLOBAL_CACHE_DIR="$GRAFTTY_ZMX_CACHE_DIR/global"
    export ZIG_LOCAL_CACHE_DIR="$stage/local"
else
    stage=$(mktemp -d)
    transient_stage=$stage
fi
if [[ ! -f "$stage/source/.graftty-prepared" ]]; then
    [[ ! -e "$stage/source" ]] || { echo "Incomplete zmx source cache: $stage/source" >&2; exit 1; }
    preparing=$(mktemp -d "$stage/preparing.XXXXXX")
    git clone --quiet https://github.com/neurosnap/zmx.git "$preparing/source"
    git -C "$preparing/source" checkout --quiet "$commit"
    for patch in "${patches[@]}"; do
        git -C "$preparing/source" apply --check "$repo/scripts/zmx/$patch"
        git -C "$preparing/source" apply "$repo/scripts/zmx/$patch"
    done
    touch "$preparing/source/.graftty-prepared"
    mv "$preparing/source" "$stage/source"
    rmdir "$preparing"
    preparing=''
fi
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
    started=$SECONDS
    zig_build_with_download_retry build test -j2 "-Dtarget=$arch-linux-musl" -Doptimize=ReleaseSafe --summary all
    echo "Zmx compile and test: $((SECONDS - started)) seconds"
    started=$SECONDS
    zig_build_with_download_retry build -j2 "-Dtarget=$arch-linux-musl" -Doptimize=ReleaseSafe \
        "-Dversion=$version-g${commit:0:7}-graftty7" --prefix "$stage/install" --summary all
    echo "Zmx ReleaseSafe build: $((SECONDS - started)) seconds"
)
mkdir -p "$(dirname "$output")"
install -m 755 "$stage/install/bin/zmx" "$output"
