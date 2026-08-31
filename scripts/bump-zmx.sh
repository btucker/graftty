#!/usr/bin/env bash
# Build the pinned, patched zmx source for both macOS architectures, verify
# upgrade compatibility against the immutable 0.5 floor and committed N-1
# binary, then update
# Resources/zmx-binary/{zmx,VERSION,CHECKSUMS}.
#
# Usage:
#   ./scripts/bump-zmx.sh
#
# Changing scripts/zmx/UPSTREAM_COMMIT is expected to require refreshing
# scripts/zmx/graftty.patch against that exact upstream revision.

set -euo pipefail

for tool in git zig lipo shasum file python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing required tool: $tool" >&2
        exit 1
    }
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$REPO/scripts/zmx/UPSTREAM_COMMIT"
PATCH_FILE="$REPO/scripts/zmx/graftty.patch"
COMPAT_TEST="$REPO/scripts/zmx/compatibility_test.py"
COMPAT_UNIT_TEST="$REPO/scripts/test_zmx_compatibility.py"
ZIG_VERSION_FILE="$REPO/scripts/zmx/ZIG_VERSION"
LEGACY_COMMIT_FILE="$REPO/scripts/zmx/LEGACY_GRAFTTY_COMMIT"
LEGACY_SHA_FILE="$REPO/scripts/zmx/LEGACY_ZMX_SHA256"
VENDORED_DIR="$REPO/Resources/zmx-binary"
VENDORED_BINARY="$VENDORED_DIR/zmx"

EXPECTED_ZIG_VERSION="$(tr -d '[:space:]' < "$ZIG_VERSION_FILE")"
ACTUAL_ZIG_VERSION="$(zig version)"
if [[ "$ACTUAL_ZIG_VERSION" != "$EXPECTED_ZIG_VERSION" ]]; then
    echo "zmx build requires Zig $EXPECTED_ZIG_VERSION, found $ACTUAL_ZIG_VERSION" >&2
    exit 1
fi

PINNED_COMMIT="$(tr -d '[:space:]' < "$PIN_FILE")"
COMMIT="$PINNED_COMMIT"
if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "UPSTREAM_COMMIT must contain a full 40-character lowercase commit SHA" >&2
    exit 1
fi

LEGACY_COMMIT="$(tr -d '[:space:]' < "$LEGACY_COMMIT_FILE")"
LEGACY_SHA="$(tr -d '[:space:]' < "$LEGACY_SHA_FILE")"
if [[ ! "$LEGACY_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "LEGACY_GRAFTTY_COMMIT must contain a full 40-character lowercase commit SHA" >&2
    exit 1
fi
if [[ ! "$LEGACY_SHA" =~ ^[0-9a-f]{64}$ ]]; then
    echo "LEGACY_ZMX_SHA256 must contain a lowercase SHA-256 digest" >&2
    exit 1
fi

TMP="$(mktemp -d /tmp/graftty-zmx-build.XXXXXX)"
INSTALL_STAGE=""
cleanup() {
    if [[ -n "$INSTALL_STAGE" ]]; then
        case "$INSTALL_STAGE" in
            "$VENDORED_DIR"/.zmx-install.*) rm -rf "$INSTALL_STAGE" ;;
            *) echo "refusing to remove unexpected install stage: $INSTALL_STAGE" >&2 ;;
        esac
    fi
    case "$TMP" in
        /tmp/graftty-zmx-build.*) rm -rf "$TMP" ;;
        *) echo "refusing to remove unexpected temp path: $TMP" >&2 ;;
    esac
}
trap cleanup EXIT

SOURCE="$TMP/zmx"
echo "→ cloning neurosnap/zmx at $COMMIT"
git clone --quiet --filter=blob:none https://github.com/neurosnap/zmx.git "$SOURCE"
git -C "$SOURCE" checkout --quiet "$COMMIT"

echo "→ applying Graftty patch"
git -C "$SOURCE" apply --check "$PATCH_FILE"
git -C "$SOURCE" apply "$PATCH_FILE"

UPSTREAM_VERSION="$(
    sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",$/\1/p' "$SOURCE/build.zig.zon"
)"
if [[ -z "$UPSTREAM_VERSION" ]]; then
    echo "couldn't read upstream version from build.zig.zon" >&2
    exit 1
fi
VERSION="${UPSTREAM_VERSION}-g${COMMIT:0:7}-graftty2"

echo "→ testing patched zmx"
(
    cd "$SOURCE"
    zig fmt --check src
    zig build test
)

declare -a checksums
for zmx_arch in aarch64 x86_64; do
    prefix="$TMP/$zmx_arch"
    echo "→ building $zmx_arch macOS"
    (
        cd "$SOURCE"
        zig build \
            "-Dtarget=${zmx_arch}-macos" \
            -Doptimize=ReleaseSafe \
            "-Dversion=$VERSION" \
            --prefix "$prefix"
    )
    binary="$prefix/bin/zmx"
    file "$binary" | grep -q "Mach-O 64-bit executable"
    actual_arch="$(lipo -archs "$binary")"
    expected_arch="$zmx_arch"
    if [[ "$zmx_arch" == "aarch64" ]]; then
        expected_arch="arm64"
    fi
    if [[ "$actual_arch" != "$expected_arch" ]]; then
        echo "unexpected architecture for $binary: $actual_arch" >&2
        exit 1
    fi
    sha="$(shasum -a 256 "$binary" | awk '{print $1}')"
    checksums+=("${sha}  zmx-${zmx_arch}")
done

CANDIDATE="$TMP/zmx-universal"
lipo -create \
    "$TMP/aarch64/bin/zmx" \
    "$TMP/x86_64/bin/zmx" \
    -output "$CANDIDATE"
chmod +x "$CANDIDATE"

if [[ "$(lipo -archs "$CANDIDATE")" != "x86_64 arm64" &&
      "$(lipo -archs "$CANDIDATE")" != "arm64 x86_64" ]]; then
    echo "candidate is not a universal x86_64/arm64 binary" >&2
    exit 1
fi
candidate_version="$(
    ZMX_DIR="$TMP/version-check" "$CANDIDATE" version |
        awk 'NR == 1 { print $2 }'
)"
if [[ "$candidate_version" != "$VERSION" ]]; then
    echo "candidate reports '$candidate_version', expected '$VERSION'" >&2
    exit 1
fi

LEGACY_BINARY="$TMP/zmx-legacy-floor"
if ! git -C "$REPO" cat-file -e \
    "$LEGACY_COMMIT:Resources/zmx-binary/zmx" 2>/dev/null; then
    echo "legacy zmx fixture commit $LEGACY_COMMIT is unavailable" >&2
    echo "fetch repository history containing that commit, then rerun" >&2
    exit 1
fi
git -C "$REPO" show \
    "$LEGACY_COMMIT:Resources/zmx-binary/zmx" > "$LEGACY_BINARY"
chmod +x "$LEGACY_BINARY"
actual_legacy_sha="$(shasum -a 256 "$LEGACY_BINARY" | awk '{print $1}')"
if [[ "$actual_legacy_sha" != "$LEGACY_SHA" ]]; then
    echo "legacy zmx fixture checksum mismatch" >&2
    exit 1
fi

echo "→ testing compatibility harness"
python3 "$COMPAT_UNIT_TEST"
echo "→ testing 0.5 compatibility floor"
python3 "$COMPAT_TEST" \
    --legacy "$LEGACY_BINARY" \
    --candidate "$CANDIDATE"

# Also exercise the committed N-1 artifact when it differs from both the
# permanent 0.5 floor and this candidate. Reading HEAD avoids turning a
# second bump in the same dirty worktree into a candidate-vs-candidate test.
PREVIOUS_BINARY="$TMP/zmx-previous"
if git -C "$REPO" show \
    "HEAD:Resources/zmx-binary/zmx" > "$PREVIOUS_BINARY" 2>/dev/null; then
    chmod +x "$PREVIOUS_BINARY"
    previous_sha="$(shasum -a 256 "$PREVIOUS_BINARY" | awk '{print $1}')"
    candidate_sha="$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')"
    if [[ "$previous_sha" != "$LEGACY_SHA" &&
          "$previous_sha" != "$candidate_sha" ]]; then
        echo "→ testing committed N-1 compatibility"
        python3 "$COMPAT_TEST" \
            --legacy "$PREVIOUS_BINARY" \
            --candidate "$CANDIDATE" \
            --expect-cross-version-pixels
    fi
fi

universal_sha="$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')"
checksums+=("${universal_sha}  zmx (universal)")
patch_sha="$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')"

mkdir -p "$VENDORED_DIR"
INSTALL_STAGE="$(mktemp -d "$VENDORED_DIR/.zmx-install.XXXXXX")"
cp "$CANDIDATE" "$INSTALL_STAGE/zmx"
chmod +x "$INSTALL_STAGE/zmx"
printf '%s\n' "$VERSION" > "$INSTALL_STAGE/VERSION"
{
    printf '# zmx %s — built from https://github.com/neurosnap/zmx commit %s\n' \
        "$VERSION" "$COMMIT"
    printf '# Built with Zig %s.\n' "$EXPECTED_ZIG_VERSION"
    printf '# Graftty patch SHA256 %s — negotiated snapshots + version-tolerant pixel sizing + no same-size redraw.\n' \
        "$patch_sha"
    printf '%s\n' "${checksums[@]}"
} > "$INSTALL_STAGE/CHECKSUMS"
staged_sha="$(shasum -a 256 "$INSTALL_STAGE/zmx" | awk '{print $1}')"
if [[ "$staged_sha" != "$universal_sha" ]]; then
    echo "staged zmx checksum mismatch" >&2
    exit 1
fi
mv "$INSTALL_STAGE/zmx" "$VENDORED_BINARY"
mv "$INSTALL_STAGE/VERSION" "$VENDORED_DIR/VERSION"
mv "$INSTALL_STAGE/CHECKSUMS" "$VENDORED_DIR/CHECKSUMS"
rmdir "$INSTALL_STAGE"
INSTALL_STAGE=""

echo
echo "✓ vendored zmx $VERSION"
echo "  source:    $COMMIT"
echo "  patch:     $patch_sha"
echo "  arm64:     ${checksums[0]%% *}"
echo "  x86_64:    ${checksums[1]%% *}"
echo "  universal: $universal_sha"
echo "  size:      $(stat -f%z "$VENDORED_BINARY") bytes"
