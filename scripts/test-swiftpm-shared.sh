#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/swiftpm"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/graftty-swiftpm-test.XXXXXX")"
ROOT_A="$FIXTURE_ROOT/root-a"
ROOT_B="$FIXTURE_ROOT/root-b"
SHARED_CACHE="$FIXTURE_ROOT/cache"
ROOT_A_PID=''
ROOT_B_PID=''
WATCHDOG_PID=''

cleanup() {
  for pid in "$WATCHDOG_PID" "$ROOT_A_PID" "$ROOT_B_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT

mkdir -p "$ROOT_A/Sources/CacheFixture"
cat > "$ROOT_A/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CacheFixture",
    products: [.executable(name: "CacheFixture", targets: ["CacheFixture"])],
    targets: [.executableTarget(name: "CacheFixture")]
)
SWIFT
printf '%s\n' 'print("root-a")' > "$ROOT_A/Sources/CacheFixture/main.swift"

git init -q "$ROOT_A"
git -C "$ROOT_A" add Package.swift Sources/CacheFixture/main.swift
git -C "$ROOT_A" \
  -c user.name='Graftty Test' \
  -c user.email='graftty-test@example.invalid' \
  commit -qm 'fixture'
git -C "$ROOT_A" worktree add -q -b root-b "$ROOT_B"
printf '%s\n' 'print("root-b")' > "$ROOT_B/Sources/CacheFixture/main.swift"

assert_output() {
  local expected="$1"
  local worktree="$2"
  local actual
  shift 2

  actual="$(
    cd "$worktree"
    GRAFTTY_SWIFTPM_SHARED_DIR="$SHARED_CACHE" \
      "$WRAPPER" run CacheFixture "$@"
  )"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected '$expected' from $worktree, got '$actual'" >&2
    exit 1
  fi
}

assert_output root-a "$ROOT_A"
assert_output root-b "$ROOT_B"
assert_output root-a "$ROOT_A"
assert_output root-a "$ROOT_A" -- --skip-build

if [[ -d "$ROOT_A/.build" || -d "$ROOT_B/.build" ]]; then
  echo 'wrapper created a worktree-local .build directory' >&2
  exit 1
fi
if [[ ! -d "$SHARED_CACHE/build" ]]; then
  echo 'wrapper did not create the shared build directory' >&2
  exit 1
fi
if (
  cd "$ROOT_A"
  GRAFTTY_SWIFTPM_SHARED_DIR="$SHARED_CACHE" \
    "$WRAPPER" test --skip-build >/dev/null 2>&1
); then
  echo 'wrapper accepted unsafe --skip-build' >&2
  exit 1
fi
if (
  cd "$ROOT_A"
  GRAFTTY_SWIFTPM_SHARED_DIR="$SHARED_CACHE" \
    "$WRAPPER" build --package-path "$ROOT_B" >/dev/null 2>&1
); then
  echo 'wrapper accepted a conflicting --package-path' >&2
  exit 1
fi

FAKE_BIN="$FIXTURE_ROOT/fake-bin"
LOCK_LOG="$FIXTURE_ROOT/lock.log"
LOCK_CACHE="$FIXTURE_ROOT/lock-cache"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/swift" <<'SH'
#!/bin/bash
printf 'start %s\n' "$LOCK_MARKER" >> "$LOCK_LOG"
sleep 0.3
printf 'end %s\n' "$LOCK_MARKER" >> "$LOCK_LOG"
SH
chmod +x "$FAKE_BIN/swift"

(
  cd "$ROOT_A"
  PATH="$FAKE_BIN:$PATH" \
    LOCK_MARKER=root-a \
    LOCK_LOG="$LOCK_LOG" \
    GRAFTTY_SWIFTPM_SHARED_DIR="$LOCK_CACHE" \
    "$WRAPPER" build
) &
ROOT_A_PID=$!
for ((attempt = 0; attempt < 500; attempt++)); do
  if [[ -f "$LOCK_LOG" ]] && grep -q '^start root-a$' "$LOCK_LOG"; then
    break
  fi
  if ! kill -0 "$ROOT_A_PID" 2>/dev/null; then
    ROOT_A_STATUS=0
    wait "$ROOT_A_PID" || ROOT_A_STATUS=$?
    ROOT_A_PID=''
    echo "first wrapper exited with status $ROOT_A_STATUS before invoking Swift" >&2
    exit 1
  fi
  sleep 0.01
done
if [[ ! -f "$LOCK_LOG" ]] || ! grep -q '^start root-a$' "$LOCK_LOG"; then
  echo 'timed out waiting for the first wrapper to invoke Swift' >&2
  exit 1
fi
(
  cd "$ROOT_B"
  PATH="$FAKE_BIN:$PATH" \
    LOCK_MARKER=root-b \
    LOCK_LOG="$LOCK_LOG" \
    GRAFTTY_SWIFTPM_SHARED_DIR="$LOCK_CACHE" \
    "$WRAPPER" build
) &
ROOT_B_PID=$!
(
  sleep 10
  echo 'timed out waiting for serialized wrapper commands' >&2
  kill "$ROOT_A_PID" "$ROOT_B_PID" 2>/dev/null || true
) &
WATCHDOG_PID=$!

ROOT_A_STATUS=0
ROOT_B_STATUS=0
wait "$ROOT_A_PID" || ROOT_A_STATUS=$?
ROOT_A_PID=''
wait "$ROOT_B_PID" || ROOT_B_STATUS=$?
ROOT_B_PID=''
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=''
if [[ "$ROOT_A_STATUS" -ne 0 || "$ROOT_B_STATUS" -ne 0 ]]; then
  echo "serialized wrappers failed: root-a=$ROOT_A_STATUS root-b=$ROOT_B_STATUS" >&2
  exit 1
fi

EXPECTED_LOCK_LOG="$(printf '%s\n' \
  'start root-a' \
  'end root-a' \
  'start root-b' \
  'end root-b')"
ACTUAL_LOCK_LOG="$(< "$LOCK_LOG")"
if [[ "$ACTUAL_LOCK_LOG" != "$EXPECTED_LOCK_LOG" ]]; then
  echo 'wrapper did not serialize complete SwiftPM command execution' >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$EXPECTED_LOCK_LOG" "$ACTUAL_LOCK_LOG" >&2
  exit 1
fi

echo 'shared SwiftPM wrapper tests passed'
