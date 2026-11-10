#!/bin/bash
set -euo pipefail
required_zig=$(tr -d '[:space:]' < "$(dirname "$0")/../../zig/VERSION")
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <patched-ghostty-source> <zig> [packaged-macos-archive]" >&2
    exit 2
fi
probe_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(cd "$1" && pwd)
zig_bin=$(command -v "$2")
zig_bin=$(cd "$(dirname "$zig_bin")" && pwd)/$(basename "$zig_bin")
[[ $("$zig_bin" version) == "$required_zig" ]] || { echo "Zig $required_zig is required." >&2; exit 2; }
probe_build=$(mktemp -d "${TMPDIR:-/tmp}/graftty-link-click.XXXXXX")
# Zig 0.17 reads the global cache only from the environment.
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$probe_build/zig-global}"
echo "Native link test artifacts: $probe_build"
# Never modify the input source or its build caches, including zig-pkg links.
mkdir "$probe_build/source"
rsync -a --exclude .zig-cache --exclude zig-out --exclude .git \
    "$source_dir/" "$probe_build/source/"
export CLANG_MODULE_CACHE_PATH="$probe_build/clang-cache"
build_library() {
    local variant=$1
    shift
    (
        cd "$probe_build/source"
        "$zig_bin" build -Demit-exe=false -Demit-macos-app=false \
            -Demit-xcframework=false -Demit-docs=false -Dsentry=false \
            -Doptimize=ReleaseSafe -Dapp-runtime=none \
            --cache-dir "$probe_build/$variant-cache" --prefix "$probe_build/$variant" \
            --summary failures "$@"
    )
}
build_library vt -Demit-lib-vt=true
if [[ $# == 2 ]]; then build_library native; fi
xcrun clang -std=c11 -Wall -Wextra -Werror -I "$probe_build/source/include" \
    "$probe_dir/make-link-fixture.c" "$probe_build/vt/lib/libghostty-vt.a" -lc++ \
    -o "$probe_build/make-link-fixture"
archive=${3:-$probe_build/native/lib/libghostty.a}
xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$probe_build/source/include" \
    "$probe_dir/link-click-probe.m" "$archive" -lc++ \
    -framework Foundation -framework Metal -framework QuartzCore -framework CoreText \
    -framework CoreGraphics -framework IOSurface -framework CoreVideo \
    -framework AppKit -framework Carbon -o "$probe_build/link-click-probe"
python3 "$probe_dir/test-link-clicks.py" "$probe_build/link-click-probe" "$probe_build/make-link-fixture"
cp "$probe_dir/test-link-clicks.py" "$probe_build/test-link-clicks.py"
echo "For SwiftPM integration, set GRAFTTY_LINK_CLICK_TEST_DIR=$probe_build"
