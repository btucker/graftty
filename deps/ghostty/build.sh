#!/bin/bash
# Build GhosttyKit.xcframework from a patched Ghostty checkout.
#
# Usage: deps/ghostty/build.sh SOURCE PLATFORMS OUTPUT
#   SOURCE     checkout prepared by `scripts/deps checkout ghostty`
#   PLATFORMS  comma-separated: macos, ios
#   OUTPUT     directory that receives GhosttyKit.xcframework
#
# Called by `scripts/deps prepare`, which supplies GRAFTTY_DEPS_ZIG (the
# pinned compiler) and GRAFTTY_DEPS_CACHE. Ported from libghostty-spm's
# Script/build-ghostty.sh, build-platform.sh and merge-xcframework.sh.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
source_dir="$(cd "${1:?Usage: build.sh SOURCE PLATFORMS OUTPUT}" && pwd)"
platforms="${2:?}"
output="${3:?}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
zig="${GRAFTTY_DEPS_ZIG:-$("$REPO/scripts/deps" zig)}"
cache="${GRAFTTY_DEPS_CACHE:?GRAFTTY_DEPS_CACHE is required}"

# Zig 0.17 takes the global cache only from the environment; package fetches
# share it with the build. Packages are verified by content hash.
export ZIG_GLOBAL_CACHE_DIR="$cache/zig-global"
export PATH="$(dirname "$zig"):$PATH"

fetch_packages() {
  local attempt
  for attempt in 1 2 3; do
    if (cd "$source_dir" && zig build --fetch=all >/dev/null); then return 0; fi
    echo "[!] Zig package fetch failed (attempt $attempt/3)" >&2
    sleep "$((attempt * 2))"
  done
  echo "[!] could not fetch Ghostty's Zig packages; see the URLs in $source_dir/build.zig.zon" >&2
  return 1
}

# Patches for fetched packages: package-patches/<package>-*.patch applies to
# every zig-pkg/<package>-* directory. Idempotent.
patch_packages() {
  local patch package dir
  for patch in "$DIR"/package-patches/*.patch; do
    [[ -f "$patch" ]] || continue
    package="$(basename "$patch")"
    package="${package%%-*}"
    set -- "$source_dir"/zig-pkg/"$package"-*
    [[ -d "$1" ]] || { echo "[!] no zig-pkg/$package-* for $(basename "$patch")" >&2; return 1; }
    for dir in "$@"; do
      if patch -s -p1 -R --dry-run -f -d "$dir" < "$patch" >/dev/null 2>&1; then continue; fi
      patch -s -p1 -f -d "$dir" < "$patch"
      echo "[+] $(basename "$patch") → $(basename "$dir")" >&2
    done
  done
}

build_target() {
  local target="$1" out="$2" sdk clang_target cpu args
  case "$target" in
    aarch64-macos) sdk=macosx; clang_target=arm64-apple-macos13.0; cpu=apple_m1 ;;
    x86_64-macos) sdk=macosx; clang_target=x86_64-apple-macos13.0; cpu= ;;
    aarch64-ios) sdk=iphoneos; clang_target=arm64-apple-ios15.0; cpu=apple_a12 ;;
    aarch64-ios-simulator) sdk=iphonesimulator; clang_target=arm64-apple-ios15.0-simulator; cpu=apple_m1 ;;
    x86_64-ios-simulator) sdk=iphonesimulator; clang_target=x86_64-apple-ios15.0-simulator; cpu= ;;
    *) echo "[!] unsupported target: $target" >&2; return 1 ;;
  esac
  mkdir -p "$out/lib" "$out/include/libghostty"
  args=(build -Demit-exe=false -Demit-macos-app=false -Demit-xcframework=false
    -Demit-docs=false -Dsentry=false -Doptimize=ReleaseSafe -Dapp-runtime=none
    "-Dtarget=$target" --cache-dir "$cache/ghostty/zig-local/$target" --prefix "$out" --summary failures)
  if [[ -n "$cpu" ]]; then args+=("-Dcpu=$cpu"); fi
  echo "[*] zig build $target" >&2
  if [[ "$target" == *-ios* ]]; then
    # Zig 0.17.0's std does not compile for iOS; use the staged patched copy.
    (cd "$source_dir" && ZIG_LIB_DIR="$("$REPO/scripts/deps" zig-lib-ios)" zig "${args[@]}")
  else
    (cd "$source_dir" && zig "${args[@]}")
  fi
  xcrun --sdk "$sdk" clang -target "$clang_target" -Os -fno-sanitize=undefined \
    -c "$DIR/support/libcxx-verbose-abort-compat.c" -o "$out/compat.o"
  xcrun libtool -static -no_warning_for_no_symbols -o "$out/lib/libghostty-compat.a" \
    "$out/lib/libghostty.a" "$out/compat.o"
  mv "$out/lib/libghostty-compat.a" "$out/lib/libghostty.a"
  rm -f "$out/compat.o"
  cp "$source_dir/include/ghostty.h" "$out/include/libghostty/ghostty.h"
  cat > "$out/include/libghostty/module.modulemap" <<'MODULE'
module libghostty {
    umbrella header "ghostty.h"
    export *
}
MODULE
}

# One xcframework library per variant: lipo the variant's targets together.
xcframework_args=()
build_variant() {
  local variant="$1" target libraries=()
  shift
  for target in "$@"; do
    build_target "$target" "$work/$target"
    libraries+=("$work/$target/lib/libghostty.a")
  done
  mkdir -p "$work/$variant/lib"
  cp -R "$work/$1/include" "$work/$variant/include"
  lipo -create "${libraries[@]}" -output "$work/$variant/lib/libghostty.a"
  xcframework_args+=(-library "$work/$variant/lib/libghostty.a" -headers "$work/$variant/include")
}

work="$output/.work"
rm -rf "$work"
mkdir -p "$work"
fetch_packages
patch_packages
for platform in $(echo "$platforms" | tr ',' ' '); do
  case "$platform" in
    macos) build_variant macosx aarch64-macos x86_64-macos ;;
    ios)
      build_variant iphoneos aarch64-ios
      build_variant iphonesimulator aarch64-ios-simulator x86_64-ios-simulator
      ;;
    *) echo "[!] unknown platform: $platform (expected macos or ios)" >&2; exit 1 ;;
  esac
done

xcodebuild -create-xcframework -output "$output/GhosttyKit.xcframework" "${xcframework_args[@]}" >/dev/null
rm -rf "$work"

# Every slice must be a static library carrying the module map and the
# architectures we asked for.
verify() {
  local slice="$output/GhosttyKit.xcframework/$1" expected="$2" actual
  [[ -f "$slice/libghostty.a" && -f "$slice/Headers/libghostty/module.modulemap" ]] \
    || { echo "[!] incomplete slice: $1" >&2; return 1; }
  actual="$(lipo -archs "$slice/libghostty.a" | tr ' ' '\n' | sort | paste -sd' ' -)"
  [[ "$actual" == "$expected" ]] || { echo "[!] $1 has architectures '$actual', expected '$expected'" >&2; return 1; }
}
for platform in $(echo "$platforms" | tr ',' ' '); do
  case "$platform" in
    macos) verify macos-arm64_x86_64 "arm64 x86_64" ;;
    ios)
      verify ios-arm64 arm64
      verify ios-arm64_x86_64-simulator "arm64 x86_64"
      ;;
  esac
done
echo "[*] GhosttyKit.xcframework ($platforms) → $output" >&2
