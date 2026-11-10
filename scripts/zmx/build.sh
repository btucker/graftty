#!/usr/bin/env bash
# Build the pinned, patched zmx for both macOS architectures.
#
# Usage: scripts/zmx/build.sh OUTPUT
#   Writes OUTPUT/zmx (universal), OUTPUT/VERSION and OUTPUT/CHECKSUMS.
#
# Called by `scripts/deps prepare zmx`, which supplies GRAFTTY_DEPS_ZIG and
# GRAFTTY_DEPS_CACHE. scripts/zmx/verify.sh runs upstream's tests and the
# compatibility checks; run it after changing the pin or a patch.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
OUTPUT="${1:?Usage: scripts/zmx/build.sh OUTPUT}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
ZIG="${GRAFTTY_DEPS_ZIG:-$("$REPO/scripts/deps" zig)}"
CACHE="${GRAFTTY_DEPS_CACHE:-$(dirname "$(dirname "$(dirname "$ZIG")")")}"
export ZIG_GLOBAL_CACHE_DIR="$CACHE/zig-global"

COMMIT="$(tr -d '[:space:]' < "$DIR/UPSTREAM_COMMIT")"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "UPSTREAM_COMMIT must be a full commit SHA" >&2; exit 1; }
GRAFTTY_REVISION="$(tr -d '[:space:]' < "$DIR/GRAFTTY_REVISION")"
[[ "$GRAFTTY_REVISION" =~ ^graftty[0-9]+$ ]] || { echo "GRAFTTY_REVISION must look like graftty<N>" >&2; exit 1; }
PATCHES=(graftty.patch paging.patch)

TMP="$(mktemp -d "${TMPDIR:-/tmp}/graftty-zmx-build.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/zmx"
git init --quiet "$SOURCE"
git -C "$SOURCE" fetch --quiet --depth=1 https://github.com/neurosnap/zmx.git "$COMMIT"
git -C "$SOURCE" checkout --quiet --detach FETCH_HEAD
for patch in "${PATCHES[@]}"; do
  git -C "$SOURCE" apply --check "$DIR/$patch" || { echo "patch failed: scripts/zmx/$patch" >&2; exit 1; }
  git -C "$SOURCE" apply "$DIR/$patch"
done

UPSTREAM_VERSION="$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",$/\1/p' "$SOURCE/build.zig.zon")"
[[ -n "$UPSTREAM_VERSION" ]] || { echo "couldn't read upstream version from build.zig.zon" >&2; exit 1; }
VERSION="${UPSTREAM_VERSION}-g${COMMIT:0:7}-${GRAFTTY_REVISION}"

checksums=()
for arch in aarch64 x86_64; do
  echo "→ building zmx $VERSION for $arch-macos" >&2
  (cd "$SOURCE" && "$ZIG" build "-Dtarget=$arch-macos" -Doptimize=ReleaseSafe \
    "-Dversion=$VERSION" --cache-dir "$CACHE/zmx-zig-local" --prefix "$TMP/$arch")
  expected="$arch"
  [[ "$arch" != aarch64 ]] || expected=arm64
  [[ "$(lipo -archs "$TMP/$arch/bin/zmx")" == "$expected" ]] || { echo "zmx $arch has the wrong architecture" >&2; exit 1; }
  checksums+=("$(shasum -a 256 "$TMP/$arch/bin/zmx" | awk '{print $1}')  zmx-$arch")
done

lipo -create "$TMP/aarch64/bin/zmx" "$TMP/x86_64/bin/zmx" -output "$OUTPUT/zmx"
chmod +x "$OUTPUT/zmx"
reported="$(ZMX_DIR="$TMP/version-check" "$OUTPUT/zmx" version | awk 'NR == 1 { print $2 }')"
[[ "$reported" == "$VERSION" ]] || { echo "zmx reports '$reported', expected '$VERSION'" >&2; exit 1; }

printf '%s\n' "$VERSION" > "$OUTPUT/VERSION"
{
  printf '# zmx %s — built from https://github.com/neurosnap/zmx commit %s\n' "$VERSION" "$COMMIT"
  printf '# Built with Zig %s.\n' "$("$ZIG" version)"
  for patch in "${PATCHES[@]}"; do
    printf '# %s SHA256 %s\n' "$patch" "$(shasum -a 256 "$DIR/$patch" | awk '{print $1}')"
  done
  printf '%s\n' "${checksums[@]}"
  printf '%s  zmx (universal)\n' "$(shasum -a 256 "$OUTPUT/zmx" | awk '{print $1}')"
} > "$OUTPUT/CHECKSUMS"
echo "✓ zmx $VERSION → $OUTPUT" >&2
