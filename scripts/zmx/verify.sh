#!/usr/bin/env bash
# Verify the pinned, patched zmx before merging a pin or patch change:
# upstream's tests, the immutable 0.5 compatibility floor, and the zmx that
# shipped in the most recent Graftty release (N-1).
#
# Usage: scripts/zmx/verify.sh [--previous PATH]
#   --previous PATH  N-1 zmx to test against instead of downloading the
#                    latest release with gh.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
PREVIOUS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --previous) PREVIOUS="$2"; shift 2 ;;
    *) echo "Usage: scripts/zmx/verify.sh [--previous PATH]" >&2; exit 64 ;;
  esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/graftty-zmx-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

"$REPO/scripts/deps" prepare zmx
CANDIDATE="$REPO/.deps/zmx/zmx"
ZIG="$("$REPO/scripts/deps" zig)"
COMMIT="$(tr -d '[:space:]' < "$DIR/UPSTREAM_COMMIT")"

echo "→ testing patched zmx"
SOURCE="$TMP/zmx"
git init --quiet "$SOURCE"
git -C "$SOURCE" fetch --quiet --depth=1 https://github.com/neurosnap/zmx.git "$COMMIT"
git -C "$SOURCE" checkout --quiet --detach FETCH_HEAD
git -C "$SOURCE" apply "$DIR/graftty.patch"
git -C "$SOURCE" apply "$DIR/paging.patch"
(
  cd "$SOURCE"
  "$ZIG" fmt --check src
  # An explicit target uses Zig's bundled Darwin libc headers, as the
  # release builds do; a native build compiles libc++ against the host SDK.
  "$ZIG" build test "-Dtarget=$(uname -m | sed 's/^arm64$/aarch64/')-macos"
)

LEGACY_COMMIT="$(tr -d '[:space:]' < "$DIR/LEGACY_GRAFTTY_COMMIT")"
LEGACY_SHA="$(tr -d '[:space:]' < "$DIR/LEGACY_ZMX_SHA256")"
LEGACY="$TMP/zmx-legacy-floor"
git -C "$REPO" cat-file -e "$LEGACY_COMMIT:Resources/zmx-binary/zmx" 2>/dev/null || {
  echo "legacy zmx fixture commit $LEGACY_COMMIT is unavailable; fetch full history and rerun" >&2
  exit 1
}
git -C "$REPO" show "$LEGACY_COMMIT:Resources/zmx-binary/zmx" > "$LEGACY"
chmod +x "$LEGACY"
[[ "$(shasum -a 256 "$LEGACY" | awk '{print $1}')" == "$LEGACY_SHA" ]] || { echo "legacy zmx fixture checksum mismatch" >&2; exit 1; }

echo "→ testing compatibility harness"
python3 -B "$REPO/scripts/test_zmx_compatibility.py"
echo "→ testing 0.5 compatibility floor"
python3 -B "$DIR/compatibility_test.py" --legacy "$LEGACY" --candidate "$CANDIDATE"

if [[ -z "$PREVIOUS" ]]; then
  tag="$(gh release list -R btucker/graftty --limit 1 --json tagName -q '.[0].tagName')"
  echo "→ downloading zmx from Graftty $tag"
  gh release download "$tag" -R btucker/graftty --pattern 'Graftty-*.zip' --dir "$TMP/release"
  ditto -x -k "$TMP"/release/Graftty-*.zip "$TMP/release"
  PREVIOUS="$TMP/release/Graftty.app/Contents/Helpers/zmx"
fi
if cmp -s "$PREVIOUS" "$CANDIDATE" || cmp -s "$PREVIOUS" "$LEGACY"; then
  echo "→ N-1 zmx matches the candidate or the floor; skipping the N-1 run"
else
  echo "→ testing N-1 compatibility"
  python3 -B "$DIR/compatibility_test.py" --legacy "$PREVIOUS" --candidate "$CANDIDATE" \
    --expect-cross-version-pixels --expect-legacy-replay-grid
fi
echo "✓ zmx $(cat "$REPO/.deps/zmx/VERSION") verified"
