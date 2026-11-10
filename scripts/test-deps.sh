#!/bin/bash
# Tests for scripts/deps: Zig pinning, the patch-series round trip, cache keys,
# locking, and platform reuse. Uses throwaway upstreams and a fake builder, so
# it needs no network and no Zig.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$REPO/scripts/deps"
FAILURES=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d ' ' -f 1
  else sha256sum "$1" | cut -d ' ' -f 1; fi
}

git_quiet() { git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# A fresh sandbox: deps root, cache, link dir, and an upstream repository with
# two commits. The patch series has two patches against the first commit.
new_sandbox() {
  local name="$1"
  SB="$WORK/$name"
  mkdir -p "$SB/deps/ghostty/patches" "$SB/deps/zig" "$SB/upstream" "$SB/cache" "$SB/link"
  cp "$REPO/deps/zig/VERSION" "$SB/deps/zig/VERSION"
  : > "$SB/deps/zig/checksums"
  git_quiet -C "$SB/upstream" init
  printf 'one\ntwo\nthree\n' > "$SB/upstream/file.txt"
  git_quiet -C "$SB/upstream" add file.txt
  git_quiet -C "$SB/upstream" commit -m base
  git -C "$SB/upstream" rev-parse HEAD > "$SB/deps/ghostty/UPSTREAM_COMMIT"
  echo "file://$SB/upstream" > "$SB/deps/ghostty/UPSTREAM_URL"
  git_quiet -C "$SB/upstream" config uploadpack.allowAnySHA1InWant true

  # Author the series by committing in a scratch clone, then exporting.
  git_quiet clone "$SB/upstream" "$SB/author"
  printf 'one\nTWO\nthree\n' > "$SB/author/file.txt"
  git_quiet -C "$SB/author" commit -am "uppercase two"
  printf 'one\nTWO\nthree\nfour\n' > "$SB/author/file.txt"
  git_quiet -C "$SB/author" commit -am "append four"
  sandbox_env "$DEPS" export ghostty "$SB/author" >/dev/null 2>&1 || fail "$name: initial export"

  cat > "$SB/builder" <<'BUILDER'
#!/bin/bash
# Fake builder: records each invocation and writes a framework-shaped dir.
set -euo pipefail
echo "$2" >> "$BUILDER_LOG"
sleep "${BUILDER_SLEEP:-0}"
mkdir -p "$3/GhosttyKit.xcframework"
cp "$1/file.txt" "$3/GhosttyKit.xcframework/source.txt"
echo "$2" > "$3/GhosttyKit.xcframework/platforms"
BUILDER
  chmod +x "$SB/builder"
  : > "$SB/builder.log"

  # A pinned "Zig" already in the sandbox cache, so prepare never downloads.
  ZIG_DIR="$SB/cache/zig/$(cat "$REPO/deps/zig/VERSION")-$("$DEPS" host)"
  mkdir -p "$ZIG_DIR"
  printf '#!/bin/sh\necho %s\n' "$(cat "$REPO/deps/zig/VERSION")" > "$ZIG_DIR/zig"
  chmod +x "$ZIG_DIR/zig"

  # A fake gate: records each run and whether the cache lock was free.
  mkdir -p "$SB/deps/ghostty/tests"
  cat > "$SB/deps/ghostty/tests/run.sh" <<'GATE'
#!/bin/bash
lock="$GRAFTTY_DEPS_CACHE/deps.lock"
if [[ "$(uname -s)" == Linux ]]; then flock -n "$lock" true; else /usr/bin/lockf -s -t 0 "$lock" true; fi
if [[ $? == 0 ]]; then echo free >> "$GATE_LOG"; else echo held >> "$GATE_LOG"; fi
GATE
  chmod +x "$SB/deps/ghostty/tests/run.sh"
  : > "$SB/gate.log"
}

sandbox_env() {
  env GRAFTTY_DEPS_ROOT="$SB/deps" GRAFTTY_DEPS_CACHE="$SB/cache" GRAFTTY_DEPS_LINK_DIR="$SB/link" \
    GRAFTTY_DEPS_GHOSTTY_BUILDER="$SB/builder" BUILDER_LOG="$SB/builder.log" GATE_LOG="$SB/gate.log" "$@"
}

builds() { wc -l < "$SB/builder.log" | tr -d ' '; }
gates() { wc -l < "$SB/gate.log" | tr -d ' '; }

test_series_export_and_order() {
  new_sandbox export
  local order
  order="$(tr '\n' ' ' < "$SB/deps/ghostty/patches/.patches")"
  [[ "$order" == "0001-uppercase-two.patch 0002-append-four.patch " ]] || fail "export order: $order"
  grep -q '^From 0000000000000000000000000000000000000000' "$SB/deps/ghostty/patches/0001-uppercase-two.patch" \
    || fail "export: patches should use --zero-commit"
  grep -q '^index [0-9a-f]\{40\}\.\.[0-9a-f]\{40\}' "$SB/deps/ghostty/patches/0001-uppercase-two.patch" \
    || fail "export: patches should carry full index lines for git am -3"
}

test_checkout_export_roundtrip() {
  new_sandbox roundtrip
  sandbox_env "$DEPS" checkout ghostty "$SB/co" >/dev/null 2>&1 || { fail "roundtrip: checkout"; return; }
  [[ "$(cat "$SB/co/file.txt")" == $'one\nTWO\nthree\nfour' ]] || fail "roundtrip: checkout content"
  printf 'one\nTWO\nthree\nfour\nfive\n' > "$SB/co/file.txt"
  git_quiet -C "$SB/co" commit -a --amend --no-edit
  sandbox_env "$DEPS" export ghostty "$SB/co" >/dev/null 2>&1 || { fail "roundtrip: export"; return; }
  grep -q '^+five' "$SB/deps/ghostty/patches/0002-append-four.patch" || fail "roundtrip: amended patch not exported"
  [[ "$(wc -l < "$SB/deps/ghostty/patches/.patches" | tr -d ' ')" == 2 ]] || fail "roundtrip: series length"
}

test_patch_failure_names_patch() {
  new_sandbox conflict
  # Move the pin to an upstream commit that conflicts with patch 0001.
  printf 'one\nzwei\nthree\n' > "$SB/upstream/file.txt"
  git_quiet -C "$SB/upstream" commit -am conflict
  git -C "$SB/upstream" rev-parse HEAD > "$SB/deps/ghostty/UPSTREAM_COMMIT"
  local output
  output="$(sandbox_env "$DEPS" prepare ghostty --platforms macos 2>&1)" && fail "conflict: prepare should fail"
  [[ "$output" == *"patch failed: 0001-uppercase-two.patch"* ]] || fail "conflict: message was: $output"
  # prepare deletes its checkout, so it must not send the user there.
  [[ "$output" != *"resolve it in $SB/cache"* ]] || fail "conflict: pointed at a deleted checkout: $output"
  [[ "$output" == *"scripts/deps checkout ghostty"* ]] || fail "conflict: no way to reproduce the conflict: $output"
  [[ -z "$(ls "$SB/cache/ghostty" 2>/dev/null | grep -v '^src$' || true)" ]] || fail "conflict: left a cached artifact"
  [[ -z "$(ls "$SB/cache/ghostty/src" 2>/dev/null || true)" ]] || fail "conflict: left a partial source dir"
  [[ ! -e "$SB/link/GhosttyKit.xcframework" ]] || fail "conflict: linked an artifact"
}

test_key_changes_with_patch() {
  new_sandbox key
  local before after
  before="$(sandbox_env "$DEPS" key ghostty --platforms macos)"
  [[ "$before" =~ ^[0-9a-f]{64}$ ]] || { fail "key: not a sha256: $before"; return; }
  [[ "$(sandbox_env "$DEPS" key ghostty --platforms macos)" == "$before" ]] || fail "key: not stable"
  echo "# touched" >> "$SB/deps/ghostty/patches/0002-append-four.patch"
  after="$(sandbox_env "$DEPS" key ghostty --platforms macos)"
  [[ "$after" != "$before" ]] || fail "key: patch edit did not change the key"
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || fail "key: prepare after edit"
}

test_prepare_links_and_reuses() {
  new_sandbox reuse
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || { fail "reuse: first prepare"; return; }
  [[ "$(cat "$SB/link/GhosttyKit.xcframework/source.txt")" == $'one\nTWO\nthree\nfour' ]] || fail "reuse: linked content"
  [[ "$(cut -d ' ' -f 1 "$SB/link/ghostty.key")" == "$(sandbox_env "$DEPS" key ghostty)" ]] || fail "reuse: key file"
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || fail "reuse: second prepare"
  [[ "$(builds)" == 1 ]] || fail "reuse: rebuilt an unchanged key ($(builds) builds)"
  rm -rf "$SB/link"
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || fail "reuse: relink"
  [[ "$(builds)" == 1 ]] || fail "reuse: relinking rebuilt"
}

test_platform_superset_reuse() {
  new_sandbox platforms
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || { fail "platforms: macos"; return; }
  sandbox_env "$DEPS" prepare ghostty --platforms ios,macos >/dev/null 2>&1 || fail "platforms: ios,macos"
  [[ "$(builds)" == 2 ]] || fail "platforms: macos-only artifact reused for ios ($(builds) builds)"
  [[ "$(cat "$SB/link/GhosttyKit.xcframework/platforms")" == "ios,macos" ]] || fail "platforms: link not updated"
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || fail "platforms: macos again"
  [[ "$(builds)" == 2 ]] || fail "platforms: superset not reused ($(builds) builds)"
}

test_concurrent_prepare_builds_once() {
  new_sandbox concurrent
  mkdir -p "$SB/link2"
  sandbox_env BUILDER_SLEEP=2 "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 &
  local first=$!
  sleep 0.5
  env GRAFTTY_DEPS_ROOT="$SB/deps" GRAFTTY_DEPS_CACHE="$SB/cache" GRAFTTY_DEPS_LINK_DIR="$SB/link2" \
    GRAFTTY_DEPS_GHOSTTY_BUILDER="$SB/builder" BUILDER_LOG="$SB/builder.log" \
    "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || fail "concurrent: second prepare"
  wait "$first" || fail "concurrent: first prepare"
  [[ "$(builds)" == 1 ]] || fail "concurrent: built $(builds) times"
  [[ -f "$SB/link/GhosttyKit.xcframework/source.txt" && -f "$SB/link2/GhosttyKit.xcframework/source.txt" ]] \
    || fail "concurrent: a link is missing its artifact"
}

test_link_dir_satisfies_prepare() {
  new_sandbox prelinked
  sandbox_env "$DEPS" prepare ghostty --platforms ios,macos >/dev/null 2>&1 || { fail "prelinked: prepare"; return; }
  # CI downloads .deps as a copied artifact; an empty cache must not rebuild it.
  local copied="$SB/copied"
  mkdir -p "$copied"
  cp -RL "$SB/link/." "$copied/"
  rm -rf "$SB/cache"
  env GRAFTTY_DEPS_ROOT="$SB/deps" GRAFTTY_DEPS_CACHE="$SB/cache" GRAFTTY_DEPS_LINK_DIR="$copied" \
    GRAFTTY_DEPS_GHOSTTY_BUILDER="$SB/builder" BUILDER_LOG="$SB/builder.log" \
    "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || fail "prelinked: second prepare"
  [[ "$(builds)" == 1 ]] || fail "prelinked: rebuilt a satisfying .deps ($(builds) builds)"
}

test_key_independent_of_checkout_path() {
  # Worktrees and CI jobs check the repository out at different paths; the
  # same inputs must produce the same key so artifacts can be shared.
  local copy="$WORK/elsewhere/repo"
  mkdir -p "$copy/scripts"
  cp -R "$REPO/deps" "$copy/deps"
  cp -R "$REPO/scripts/zmx" "$copy/scripts/zmx"
  cp "$REPO/scripts/deps" "$copy/scripts/deps"
  local name
  for name in ghostty zmx; do
    [[ "$(GRAFTTY_DEPS_CACHE="$WORK/keycache" "$copy/scripts/deps" key "$name")" == \
       "$(GRAFTTY_DEPS_CACHE="$WORK/keycache" "$DEPS" key "$name")" ]] || fail "key: $name depends on the checkout path"
  done
}

test_zig_checksum_mismatch() {
  local sb="$WORK/zig"
  mkdir -p "$sb/payload/zig-fake" "$sb/cache"
  printf '#!/bin/sh\necho %s\n' "$(cat "$REPO/deps/zig/VERSION")" > "$sb/payload/zig-fake/zig"
  chmod +x "$sb/payload/zig-fake/zig"
  tar -cJf "$sb/zig.tar.xz" -C "$sb/payload" zig-fake
  local host
  host="$("$DEPS" host)"
  echo "$host 0000000000000000000000000000000000000000000000000000000000000000 file://$sb/zig.tar.xz" > "$sb/bad"
  GRAFTTY_DEPS_CACHE="$sb/cache" GRAFTTY_DEPS_ZIG_CHECKSUMS="$sb/bad" "$DEPS" zig >/dev/null 2>&1 \
    && fail "zig: accepted a wrong checksum"
  [[ -z "$(ls "$sb/cache/zig" 2>/dev/null || true)" ]] || fail "zig: left files after a bad checksum"
  echo "$host $(sha256_file "$sb/zig.tar.xz") file://$sb/zig.tar.xz" > "$sb/good"
  local path
  path="$(GRAFTTY_DEPS_CACHE="$sb/cache" GRAFTTY_DEPS_ZIG_CHECKSUMS="$sb/good" "$DEPS" zig 2>/dev/null)" \
    || { fail "zig: rejected a good checksum"; return; }
  [[ "$("$path" version)" == "$(cat "$REPO/deps/zig/VERSION")" ]] || fail "zig: wrong binary at $path"
}

test_zig_extract_failure_installs_nothing() {
  local sb="$WORK/zig-extract"
  mkdir -p "$sb/cache/zig/.stage.stale"
  echo "not an xz tarball" > "$sb/zig.tar.xz"
  echo "$("$DEPS" host) $(sha256_file "$sb/zig.tar.xz") file://$sb/zig.tar.xz" > "$sb/checksums"
  GRAFTTY_DEPS_CACHE="$sb/cache" GRAFTTY_DEPS_ZIG_CHECKSUMS="$sb/checksums" "$DEPS" zig >/dev/null 2>&1 \
    && fail "zig-extract: accepted an unreadable tarball"
  [[ -z "$(ls -A "$sb/cache/zig" 2>/dev/null || true)" ]] || fail "zig-extract: left $(ls -A "$sb/cache/zig")"
}

test_prepare_requires_zig() {
  new_sandbox nozig
  rm -rf "$ZIG_DIR"
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 && fail "nozig: prepare succeeded without Zig"
  [[ "$(builds)" == 0 ]] || fail "nozig: ran the builder without Zig"
}

test_fetch_failure_is_not_a_patch_failure() {
  new_sandbox offline
  echo "file://$SB/missing" > "$SB/deps/ghostty/UPSTREAM_URL"
  local output
  output="$(sandbox_env "$DEPS" prepare ghostty --platforms macos 2>&1)" && fail "offline: prepare should fail"
  [[ "$output" == *"could not fetch"* ]] || fail "offline: message was: $output"
  [[ "$output" != *"patch failed"* ]] || fail "offline: blamed a patch: $output"
}

test_series_last_line_without_newline() {
  new_sandbox newline
  printf '0001-uppercase-two.patch\n0002-append-four.patch' > "$SB/deps/ghostty/patches/.patches"
  sandbox_env "$DEPS" checkout ghostty "$SB/co" >/dev/null 2>&1 || { fail "newline: checkout"; return; }
  [[ "$(cat "$SB/co/file.txt")" == $'one\nTWO\nthree\nfour' ]] || fail "newline: dropped the last patch"
}

test_unlisted_patch_is_an_error() {
  new_sandbox unlisted
  cp "$SB/deps/ghostty/patches/0002-append-four.patch" "$SB/deps/ghostty/patches/0003-forgotten.patch"
  local output
  output="$(sandbox_env "$DEPS" checkout ghostty "$SB/co" 2>&1)" && fail "unlisted: checkout ignored 0003"
  [[ "$output" == *"0003-forgotten.patch"* ]] || fail "unlisted: message was: $output"
}

test_round_trip_ignores_user_git_config() {
  new_sandbox gitconfig
  printf '[format]\n\tsignOff = true\n\tcoverLetter = true\n\tsuffix = .txt\n[commit]\n\tgpgSign = true\n[gpg]\n\tprogram = false\n' \
    > "$SB/gitconfig"
  GIT_CONFIG_GLOBAL="$SB/gitconfig" sandbox_env "$DEPS" checkout ghostty "$SB/co" >/dev/null 2>&1 \
    || { fail "gitconfig: checkout honored commit.gpgSign"; return; }
  GIT_CONFIG_GLOBAL="$SB/gitconfig" sandbox_env "$DEPS" export ghostty "$SB/co" >/dev/null 2>&1 \
    || { fail "gitconfig: export"; return; }
  [[ "$(tr '\n' ' ' < "$SB/deps/ghostty/patches/.patches")" == "0001-uppercase-two.patch 0002-append-four.patch " ]] \
    || fail "gitconfig: series was $(tr '\n' ' ' < "$SB/deps/ghostty/patches/.patches")"
  ! grep -q '^Signed-off-by' "$SB/deps/ghostty/patches/"*.patch || fail "gitconfig: export honored format.signOff"
}

test_prepare_clears_interrupted_builds() {
  new_sandbox interrupted
  local key
  key="$(sandbox_env "$DEPS" key ghostty)"
  mkdir -p "$SB/cache/ghostty/$key/.build.99999/GhosttyKit.xcframework"
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || { fail "interrupted: prepare"; return; }
  [[ ! -e "$SB/cache/ghostty/$key/.build.99999" ]] || fail "interrupted: kept a stale ghostty stage"
}

test_gate_once_reruns_when_the_gate_changes() {
  new_sandbox gate
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || { fail "gate: prepare"; return; }
  sandbox_env "$DEPS" test ghostty --once >/dev/null 2>&1 || fail "gate: first run"
  sandbox_env "$DEPS" test ghostty --once >/dev/null 2>&1 || fail "gate: second run"
  [[ "$(gates)" == 1 ]] || fail "gate: --once reran an unchanged gate ($(gates) runs)"
  echo "# a new probe" >> "$SB/deps/ghostty/tests/run.sh"
  sandbox_env "$DEPS" test ghostty --once >/dev/null 2>&1 || fail "gate: third run"
  [[ "$(gates)" == 2 ]] || fail "gate: --once skipped a changed gate ($(gates) runs)"
}

test_gate_refuses_a_stale_link() {
  new_sandbox stalegate
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || { fail "stalegate: prepare"; return; }
  echo "# touched" >> "$SB/deps/ghostty/patches/0002-append-four.patch"
  local output
  output="$(sandbox_env "$DEPS" test ghostty 2>&1)" && fail "stalegate: tested a stale library"
  [[ "$output" == *"scripts/deps prepare"* ]] || fail "stalegate: message was: $output"
  [[ "$(gates)" == 0 ]] || fail "stalegate: ran the gate"
}

test_gate_runs_without_the_cache_lock() {
  new_sandbox gatelock
  sandbox_env "$DEPS" prepare ghostty --platforms macos >/dev/null 2>&1 || { fail "gatelock: prepare"; return; }
  sandbox_env "$DEPS" test ghostty >/dev/null 2>&1 || fail "gatelock: gate"
  [[ "$(cat "$SB/gate.log")" == free ]] || fail "gatelock: the gate held the cache lock ($(cat "$SB/gate.log"))"
}

test_ghostty_build_stops_when_ios_std_fails() {
  # deps/ghostty/build.sh in a scratch repo whose scripts/deps cannot stage
  # the iOS std; the build must stop before compiling an iOS slice.
  local sb="$WORK/ios-std"
  mkdir -p "$sb/repo/deps/ghostty/package-patches" "$sb/repo/scripts" "$sb/bin" "$sb/source/include" "$sb/out"
  cp "$REPO/deps/ghostty/build.sh" "$sb/repo/deps/ghostty/build.sh"
  printf '#!/bin/sh\necho "cannot stage std" >&2\nexit 1\n' > "$sb/repo/scripts/deps"
  printf '#!/bin/sh\necho "$*" >> "%s"\n' "$sb/zig.log" > "$sb/bin/zig"
  chmod +x "$sb/repo/scripts/deps" "$sb/bin/zig"
  : > "$sb/zig.log"
  GRAFTTY_DEPS_ZIG="$sb/bin/zig" GRAFTTY_DEPS_CACHE="$sb/cache" \
    "$sb/repo/deps/ghostty/build.sh" "$sb/source" ios "$sb/out" >/dev/null 2>&1 \
    && fail "ios-std: build succeeded"
  ! grep -q -- '-Dtarget=aarch64-ios' "$sb/zig.log" || fail "ios-std: compiled iOS without the patched std"
}

test_zig_checksums_cover_ci_hosts() {
  local host
  for host in aarch64-macos x86_64-macos x86_64-linux aarch64-linux; do
    grep -Eq "^$host [0-9a-f]{64} https://ziglang.org/download/$(cat "$REPO/deps/zig/VERSION")/" "$REPO/deps/zig/checksums" \
      || fail "zig checksums: missing $host"
  done
}

for test in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$test"
done

if [[ "$FAILURES" -ne 0 ]]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "scripts/deps: all tests passed"
