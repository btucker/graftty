#!/usr/bin/env bash
# Build the pinned snapshot renderer and Swift wrapper into a local Swift package.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
patches="$repo/scripts/ghostty-paging"
output="$repo/.dependencies/libghostty-spm"
cache="${GRAFTTY_GHOSTTY_BUILD_CACHE:-$HOME/Library/Caches/Graftty/GhosttyPaging}"
zig_bin="${ZIG:-zig}"
arm64_only=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        --cache) cache=$2; shift 2 ;;
        --zig) zig_bin=$2; shift 2 ;;
        --arm64-only) arm64_only=true; shift ;;
        --help)
            echo "Usage: $0 [--zig PATH] [--output PATH] [--cache PATH] [--arm64-only]"
            echo "Default: universal macOS, arm64 iOS, universal iOS Simulator."
            echo "Output: .dependencies/libghostty-spm; no upload or publication."
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
for tool in git xcrun xcodebuild lipo shasum python3; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
zig_bin=$(command -v "$zig_bin")
zig_bin=$(cd "$(dirname "$zig_bin")" && pwd)/$(basename "$zig_bin")
[[ $("$zig_bin" version) == 0.16.0 ]] || { echo "Zig 0.16.0 is required." >&2; exit 1; }
xcrun metal --version >/dev/null

renderer_pin=8af6897c0afc63037a8a3efee4162a380e3a4572
wrapper_pin=52a84d611b1442dbeffa972b37022346a8a32ec6
renderer_patches=(preserve-top-anchor resize-history-guard renderer-experiment ios-renderer-experiment production-snapshot history-viewport)
mkdir -p "$cache" "$(dirname "$output")"
cache=$(cd "$cache" && pwd)
output=$(cd "$(dirname "$output")" && pwd)/$(basename "$output")
# The source cache changes whenever a renderer patch changes. Completed builds
# reuse Zig's compilation cache while source and archive outputs stay isolated.
fingerprint=$(
    { printf '%s\n' "$renderer_pin"; for name in "${renderer_patches[@]}"; do cat "$patches/$name.patch"; done; } |
        shasum -a 256 | awk '{print $1}'
)
work="$cache/$fingerprint"
source="$work/ghostty"
mkdir -p "$work"
checkout() {
    local url=$1 pin=$2 target=$3
    git init --quiet "$target"
    git -C "$target" remote add origin "$url"
    git -C "$target" fetch --quiet --depth 1 origin "$pin"
    git -C "$target" checkout --quiet --detach FETCH_HEAD
    [[ $(git -C "$target" rev-parse HEAD) == "$pin" ]]
}
if [[ ! -f "$source/.graftty-patches-applied" ]]; then
    if [[ -e "$source" ]]; then
        echo "Incomplete source cache: $source. Remove that directory and retry." >&2
        exit 1
    fi
    checkout https://github.com/ghostty-org/ghostty.git "$renderer_pin" "$source"
    for name in "${renderer_patches[@]}"; do
        git -C "$source" apply --check "$patches/$name.patch"
        git -C "$source" apply "$patches/$name.patch"
    done
    touch "$source/.graftty-patches-applied"
fi

stage=$(mktemp -d "$(dirname "$output")/.libghostty-paging.XXXXXX")
cleanup() {
    if [[ -n "$stage" && -d "$stage" ]]; then rm -rf "$stage"; fi
}
trap cleanup EXIT
checkout https://github.com/btucker/libghostty-spm.git "$wrapper_pin" "$stage"
git -C "$stage" apply --check "$patches/production-wrapper.patch"
git -C "$stage" apply "$patches/production-wrapper.patch"
git -C "$stage" apply --check "$patches/history-wrapper.patch"
git -C "$stage" apply "$patches/history-wrapper.patch"
cp "$stage/Package.local.swift" "$stage/Package.swift"

build_archive() {
    local name=$1 target=$2 cpu=$3 clang_target=$4 sdk=$5
    local out="$work/$name" object="$work/$name-compat.o"
    echo "Building $name ($target)"
    local args=(build -Demit-exe=false -Demit-macos-app=false -Demit-xcframework=false
        -Demit-docs=false -Dsentry=false -Doptimize=ReleaseSafe -Dapp-runtime=none
        "-Dtarget=$target" --global-cache-dir "$cache/zig-global"
        --cache-dir "$work/$name-cache" --prefix "$out" --summary failures)
    if [[ -n "$cpu" ]]; then args+=("-Dcpu=$cpu"); fi
    (cd "$source"; "$zig_bin" "${args[@]}")
    # Zig's libc++ headers reference this symbol on older Apple runtimes.
    xcrun --sdk "$sdk" clang -target "$clang_target" -Os -fno-sanitize=undefined \
        -c "$stage/Script/support/libcxx-verbose-abort-compat.c" -o "$object"
    xcrun libtool -static -no_warning_for_no_symbols -o "$out/lib/libghostty-compat.a" \
        "$out/lib/libghostty.a" "$object"
}
build_archive macos-arm64 aarch64-macos apple_m1 arm64-apple-macos13.0 macosx
build_archive ios-arm64 aarch64-ios apple_a12 arm64-apple-ios15.0 iphoneos
build_archive simulator-arm64 aarch64-ios-simulator apple_m1 arm64-apple-ios15.0-simulator iphonesimulator
if [[ "$arm64_only" == false ]]; then
    build_archive macos-x86_64 x86_64-macos '' x86_64-apple-macos13.0 macosx
    build_archive simulator-x86_64 x86_64-ios-simulator '' x86_64-apple-ios15.0-simulator iphonesimulator
fi

for platform in macos ios simulator; do
    mkdir -p "$stage/build/$platform/include/libghostty" "$stage/build/$platform/lib"
    cp "$source/include/ghostty.h" "$stage/build/$platform/include/libghostty/ghostty.h"
    cat > "$stage/build/$platform/include/libghostty/module.modulemap" <<'MODULE'
module libghostty {
    umbrella header "ghostty.h"
    export *
}
MODULE
    archives=("$work/$platform-arm64/lib/libghostty-compat.a")
    if [[ "$arm64_only" == false && "$platform" != ios ]]; then
        archives+=("$work/$platform-x86_64/lib/libghostty-compat.a")
    fi
    lipo -create "${archives[@]}" -output "$stage/build/$platform/lib/libghostty.a"
done
mkdir -p "$stage/BinaryTarget"
xcodebuild -create-xcframework \
    -library "$stage/build/macos/lib/libghostty.a" -headers "$stage/build/macos/include" \
    -library "$stage/build/ios/lib/libghostty.a" -headers "$stage/build/ios/include" \
    -library "$stage/build/simulator/lib/libghostty.a" -headers "$stage/build/simulator/include" \
    -output "$stage/BinaryTarget/GhosttyKit.xcframework"
python3 - "$stage/BinaryTarget/GhosttyKit.xcframework/Info.plist" "$arm64_only" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    libraries = plistlib.load(stream)['AvailableLibraries']
expected = {'arm64'} if sys.argv[2] == 'true' else {'arm64', 'x86_64'}
found = {(entry['SupportedPlatform'], entry.get('SupportedPlatformVariant')):
         set(entry['SupportedArchitectures']) for entry in libraries}
assert found == {('macos', None): expected, ('ios', None): {'arm64'},
                 ('ios', 'simulator'): expected}, found
PY
{
    printf 'renderer %s\nwrapper %s\nzig 0.16.0\narm64_only %s\n' "$renderer_pin" "$wrapper_pin" "$arm64_only"
    for name in "${renderer_patches[@]}" production-wrapper history-wrapper; do
        (cd "$patches"; shasum -a 256 "$name.patch")
    done
} > "$stage/PAGING-BUILD.txt"
# Keep only the packaged archives, not their duplicate pre-XCFramework copies.
rm -rf "$stage/build"
if [[ -e "$output" ]]; then
    [[ -f "$output/PAGING-BUILD.txt" ]] || { echo "Refusing to replace an unmarked package: $output" >&2; exit 1; }
    previous="$output.previous.$$"
    mv "$output" "$previous"
    if ! mv "$stage" "$output"; then mv "$previous" "$output"; exit 1; fi
    rm -rf "$previous"
else
    mv "$stage" "$output"
fi
stage=''
echo "Built paging dependency: $output"
echo "Open or resolve the Graftty package again to use the rebuilt dependency."
