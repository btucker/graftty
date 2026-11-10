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
}

sandbox_env() {
  env GRAFTTY_DEPS_ROOT="$SB/deps" GRAFTTY_DEPS_CACHE="$SB/cache" GRAFTTY_DEPS_LINK_DIR="$SB/link" \
    GRAFTTY_DEPS_GHOSTTY_BUILDER="$SB/builder" BUILDER_LOG="$SB/builder.log" "$@"
}

builds() { wc -l < "$SB/builder.log" | tr -d ' '; }

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
