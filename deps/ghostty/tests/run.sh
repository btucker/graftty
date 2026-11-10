#!/bin/bash
# The Ghostty compatibility gate: run after moving the pin or editing the
# patch series. Called by `scripts/deps test ghostty`.
#
# Usage: deps/ghostty/tests/run.sh SOURCE XCFRAMEWORK [simulator-udid]
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$dir/../../.." && pwd)"
source_dir="${1:?Usage: run.sh SOURCE XCFRAMEWORK [simulator-udid]}"
xcframework="${2:?}"
zig="${GRAFTTY_DEPS_ZIG:-$("$repo/scripts/deps" zig)}"
cache="${GRAFTTY_DEPS_CACHE:?}"
export ZIG_GLOBAL_CACHE_DIR="$cache/zig-global"

# Probes build into TMPDIR; keep them in one directory and delete it after,
# since each probe build holds several gigabytes of Zig cache.
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/graftty-ghostty-gate.XXXXXX")"
export TMPDIR
[[ -n "${GRAFTTY_DEPS_KEEP_TEST_ARTIFACTS:-}" ]] || trap 'rm -rf "$TMPDIR"' EXIT

echo "== core paging probes"
"$dir/test-core.sh" "$source_dir" "$zig"
echo "== production surfaces (packaged library)"
LIBGHOSTTY_TEST_XCFRAMEWORK="$xcframework" "$dir/production-test-surfaces.sh" "$source_dir" "$zig" ${3:+"$3"}
echo "== lib-vt snapshot tests"
(cd "$source_dir" && "$zig" build test-lib-vt -Dtest-filter=snapshot.snapshot \
  --cache-dir "$TMPDIR/lib-vt" --summary failures)
echo "== licenses"
"$dir/check-licenses.sh"
echo "Ghostty gate: PASS"
