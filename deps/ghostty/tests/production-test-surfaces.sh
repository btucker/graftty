#!/bin/bash
set -euo pipefail
required_zig=$(tr -d '[:space:]' < "$(dirname "$0")/../../zig/VERSION")

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <patched-ghostty-source> <zig-executable> [simulator-udid]" >&2
    exit 2
fi
probe_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ghostty_source=$(cd "$1" && pwd)
zig_bin=$(command -v "$2")
zig_bin=$(cd "$(dirname "$zig_bin")" && pwd)/$(basename "$zig_bin")
if [[ $("$zig_bin" version) != "$required_zig" ]]; then
    echo "This test requires Zig $required_zig." >&2
    exit 2
fi
xcrun --sdk macosx metal --version

probe_build=$(mktemp -d "${TMPDIR:-/tmp}/graftty-surface-probe.XXXXXX")
# Zig 0.17 reads the global cache only from the environment.
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$probe_build/zig-global}"
echo "Native paging test artifacts: $probe_build"
probe_cflags=()
if [[ ${GRAFTTY_SELECTION_RESIZE_PROBE:-0} == 1 ]]; then
    # The deterministic mouse/resize seam is never compiled into production
    # packages. Copy source without build caches and patch only this copy.
    mkdir "$probe_build/source"
    rsync -a --exclude .zig-cache --exclude zig-out --exclude .git \
        "$ghostty_source/" "$probe_build/source/"
    ghostty_source="$probe_build/source"
    git -C "$ghostty_source" apply "$probe_dir/production-selection-probe.patch"
    probe_cflags=(-DGRAFTTY_SELECTION_RESIZE_PROBE=1)
fi
common_args=(
    -Demit-exe=false -Demit-macos-app=false -Demit-xcframework=false
    -Demit-docs=false -Dsentry=false -Doptimize=ReleaseSafe
)
build_library() {
    local variant=$1
    shift
    (
        cd "$ghostty_source"
        "$zig_bin" build "${common_args[@]}" \
            --prefix "$probe_build/$variant" --cache-dir "$probe_build/$variant-cache" "$@"
    )
}

build_library core -Demit-lib-vt=true
if [[ -n ${LIBGHOSTTY_TEST_XCFRAMEWORK:-} ]]; then
    [[ ${GRAFTTY_SELECTION_RESIZE_PROBE:-0} == 0 ]] || { echo 'Test seam requires a source build' >&2; exit 2; }
    packaged_library() {
        python3 - "$LIBGHOSTTY_TEST_XCFRAMEWORK" "$1" <<'LOOKUP'
from pathlib import Path
import plistlib, sys
root=Path(sys.argv[1]).resolve()
with (root/'Info.plist').open('rb') as stream:
    entries=plistlib.load(stream)['AvailableLibraries']
entry=next(e for e in entries if e['SupportedPlatform']==sys.argv[2]
           and e.get('SupportedPlatformVariant')==('simulator' if sys.argv[2]=='ios' else None))
print(root/entry['LibraryIdentifier']/entry['LibraryPath'])
LOOKUP
    }
    macos_library=$(packaged_library macos)
else
    build_library macos -Dapp-runtime=none
    macos_library="$probe_build/macos/lib/libghostty.a"
fi
xcrun clang -std=c11 -Wall -Wextra -Werror -DGHOSTTY_STATIC \
    -I "$ghostty_source/include" "$probe_dir/make-fixture.c" \
    "$probe_build/core/lib/libghostty-vt.a" -lc++ -o "$probe_build/make-fixture"
"$probe_build/make-fixture" "$probe_build/surface-fixture.bin"
"$probe_build/make-fixture" "$probe_build/surface-modes.bin" --modes

frameworks=(
    -framework Foundation -framework Metal -framework QuartzCore -framework CoreText
    -framework CoreGraphics -framework IOSurface -framework CoreVideo
)
xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$ghostty_source/include" \
    ${probe_cflags[@]+"${probe_cflags[@]}"} \
    "$probe_dir/production-surface-probe.m" "$macos_library" -lc++ \
    "${frameworks[@]}" -framework AppKit -framework Carbon -o "$probe_build/surface-probe"
"$probe_build/surface-probe" "$probe_build/surface-fixture.bin" "$probe_build/surface-modes.bin"

if [[ $# == 2 ]]; then
    echo "UIKit test skipped. Pass a simulator UDID to run both platforms."
    exit 0
fi

if [[ -n ${LIBGHOSTTY_TEST_XCFRAMEWORK:-} ]]; then
    ios_library=$(packaged_library ios)
else
    # Zig 0.17.0's std needs the staged iOS patch, as in deps/ghostty/build.sh.
    ios_zig_lib=$("$probe_dir/../../../scripts/deps" zig-lib-ios)
    ZIG_LIB_DIR=$ios_zig_lib build_library ios -Dapp-runtime=none -Dtarget=aarch64-ios-simulator -Dcpu=apple_m1
    ios_library="$probe_build/ios/lib/libghostty.a"
fi
probe_app="$probe_build/SurfaceProbe.app"
mkdir "$probe_app"
cp "$probe_dir/SurfaceProbe-Info.plist" "$probe_app/Info.plist"
cp "$probe_build/surface-fixture.bin" "$probe_app/surface-fixture.bin"
cp "$probe_build/surface-modes.bin" "$probe_app/surface-modes.bin"
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun clang -fobjc-arc -Wall -Wextra -Werror -target arm64-apple-ios15.0-simulator \
    ${probe_cflags[@]+"${probe_cflags[@]}"} \
    -isysroot "$simulator_sdk" -I "$ghostty_source/include" \
    "$probe_dir/production-surface-probe.m" "$ios_library" -lc++ \
    "${frameworks[@]}" -framework UIKit -o "$probe_app/SurfaceProbe"
codesign --sign - "$probe_app"
xcrun simctl bootstatus "$3" -b
xcrun simctl install "$3" "$probe_app"
xcrun simctl launch --console "$3" dev.graftty.snapshot-probe | tee "$probe_build/ios.log"
# simctl can return success even when the launched app asserts. Require the
# final scenario's marker, which is emitted only after all assertions pass.
grep -q '^UIKit snapshot surface: scenario=9 pages=0 READY/live/draw/destroy PASS' "$probe_build/ios.log"
