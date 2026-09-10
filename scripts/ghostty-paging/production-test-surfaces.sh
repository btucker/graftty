#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <patched-ghostty-source> <zig-0.16.0-executable> [simulator-udid]" >&2
    exit 2
fi
probe_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ghostty_source=$(cd "$1" && pwd)
zig_bin=$(command -v "$2")
zig_bin=$(cd "$(dirname "$zig_bin")" && pwd)/$(basename "$zig_bin")
if [[ $("$zig_bin" version) != 0.16.0 ]]; then
    echo "This test requires Zig 0.16.0." >&2
    exit 2
fi
xcrun metal --version

probe_build=$(mktemp -d "${TMPDIR:-/tmp}/graftty-surface-probe.XXXXXX")
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
    --global-cache-dir "${ZIG_GLOBAL_CACHE_DIR:-$probe_build/zig-global}"
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
build_library macos -Dapp-runtime=none
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
    "${probe_cflags[@]}" \
    "$probe_dir/production-surface-probe.m" "$probe_build/macos/lib/libghostty.a" -lc++ \
    "${frameworks[@]}" -framework AppKit -framework Carbon -o "$probe_build/surface-probe"
"$probe_build/surface-probe" "$probe_build/surface-fixture.bin" "$probe_build/surface-modes.bin"

if [[ $# == 2 ]]; then
    echo "UIKit test skipped. Pass a simulator UDID to run both platforms."
    exit 0
fi

build_library ios -Dapp-runtime=none -Dtarget=aarch64-ios-simulator -Dcpu=apple_m1
probe_app="$probe_build/SurfaceProbe.app"
mkdir "$probe_app"
cp "$probe_dir/SurfaceProbe-Info.plist" "$probe_app/Info.plist"
cp "$probe_build/surface-fixture.bin" "$probe_app/surface-fixture.bin"
cp "$probe_build/surface-modes.bin" "$probe_app/surface-modes.bin"
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun clang -fobjc-arc -Wall -Wextra -Werror -target arm64-apple-ios15.0-simulator \
    "${probe_cflags[@]}" \
    -isysroot "$simulator_sdk" -I "$ghostty_source/include" \
    "$probe_dir/production-surface-probe.m" "$probe_build/ios/lib/libghostty.a" -lc++ \
    "${frameworks[@]}" -framework UIKit -o "$probe_app/SurfaceProbe"
codesign --sign - "$probe_app"
xcrun simctl bootstatus "$3" -b
xcrun simctl install "$3" "$probe_app"
xcrun simctl launch --console "$3" dev.graftty.snapshot-probe | tee "$probe_build/ios.log"
# simctl can return success even when the launched app asserts. Require the
# final scenario's marker, which is emitted only after all assertions pass.
rg -q '^UIKit snapshot surface: scenario=9 pages=0 READY/live/draw/destroy PASS' "$probe_build/ios.log"
