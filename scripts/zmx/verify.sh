#!/usr/bin/env bash
# Verify the pinned, patched zmx before merging a pin or patch change:
# upstream's tests, the immutable 0.5 compatibility floor, and the zmx that
# shipped in the most recent Graftty release (N-1).
#
# Usage: scripts/zmx/verify.sh [--previous PATH] [--once]
#   --previous PATH  N-1 zmx to test against instead of downloading it from
#                    the latest Graftty release.
#   --once           Skip a zmx key whose checks already passed on this
#                    machine (CI's native-deps job).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
PREVIOUS=""
ONCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --previous) PREVIOUS="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    *) echo "Usage: scripts/zmx/verify.sh [--previous PATH] [--once]" >&2; exit 64 ;;
  esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/graftty-zmx-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

"$REPO/scripts/deps" prepare zmx
CANDIDATE="$REPO/.deps/zmx/zmx"
# A pass is recorded per zmx key and per version of these checks.
checks="$(cat "$0" "$DIR/compatibility_test.py" "$REPO/scripts/test_zmx_compatibility.py" \
  "$DIR/LEGACY_GRAFTTY_COMMIT" "$DIR/LEGACY_ZMX_SHA256" | shasum -a 256 | cut -c1-16)"
MARKER="$("$REPO/scripts/deps" cache-dir)/zmx/$("$REPO/scripts/deps" key zmx)/.verified.$checks"
if [[ "$ONCE" == 1 && -f "$MARKER" ]]; then
  echo "✓ zmx checks already passed for $(cat "$REPO/.deps/zmx/VERSION")"
  exit 0
fi
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
if ! git -C "$REPO" cat-file -e "$LEGACY_COMMIT:Resources/zmx-binary/zmx" 2>/dev/null; then
  # Shallow CI checkouts lack the fixture commit; fetch just that commit.
  git -C "$REPO" fetch --quiet --depth=1 origin "$LEGACY_COMMIT" || {
    echo "legacy zmx fixture commit $LEGACY_COMMIT is unavailable" >&2
    exit 1
  }
fi
git -C "$REPO" show "$LEGACY_COMMIT:Resources/zmx-binary/zmx" > "$LEGACY"
chmod +x "$LEGACY"
[[ "$(shasum -a 256 "$LEGACY" | awk '{print $1}')" == "$LEGACY_SHA" ]] || { echo "legacy zmx fixture checksum mismatch" >&2; exit 1; }

echo "→ testing compatibility harness"
python3 -B "$REPO/scripts/test_zmx_compatibility.py"
echo "→ testing 0.5 compatibility floor"
python3 -B "$DIR/compatibility_test.py" --legacy "$LEGACY" --candidate "$CANDIDATE"

if [[ -z "$PREVIOUS" ]]; then
  # The latest release in any channel: prerelease users run its daemons too.
  release="$(curl --retry 3 -fsSL "https://api.github.com/repos/btucker/graftty/releases?per_page=1")"
  read -r tag url < <(python3 -c '
import json, sys
release = json.load(sys.stdin)[0]
asset = next(a for a in release["assets"] if a["name"].startswith("Graftty-") and a["name"].endswith(".zip"))
print(release["tag_name"], asset["browser_download_url"])' <<<"$release")
  echo "→ downloading zmx from Graftty $tag"
  mkdir -p "$TMP/release"
  curl --retry 3 -fsSL "$url" -o "$TMP/release/Graftty.zip"
  ditto -x -k "$TMP/release/Graftty.zip" "$TMP/release"
  PREVIOUS="$TMP/release/Graftty.app/Contents/Helpers/zmx"
fi
if cmp -s "$PREVIOUS" "$CANDIDATE" || cmp -s "$PREVIOUS" "$LEGACY"; then
  echo "→ N-1 zmx matches the candidate or the floor; skipping the N-1 run"
else
  echo "→ testing N-1 compatibility"
  python3 -B "$DIR/compatibility_test.py" --legacy "$PREVIOUS" --candidate "$CANDIDATE" \
    --expect-cross-version-pixels --expect-legacy-replay-grid
fi
mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
echo "✓ zmx $(cat "$REPO/.deps/zmx/VERSION") verified"
