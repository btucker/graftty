# In-repo Dependency Patching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `btucker/libghostty-spm` fork with a pinned Ghostty commit plus an Electron-style patch series in this repo, built on demand behind an input-keyed cache, and make zmx use the same cache instead of a committed binary.

**Architecture:** `deps/` holds pins, patch series, and the Zig pin. One driver, `scripts/deps`, fetches pinned sources into a shared cache, applies the series with `git am -3`, builds with an auto-downloaded Zig, and links the result into the git-ignored `.deps/` directory that `Package.swift` and `bundle.sh` read. CI builds once per key on mini-m1 and hands the artifacts to hosted test jobs; releases rebuild from source.

**Tech Stack:** bash (macOS bash 3.2 compatible), git, Zig 0.17.0, xcodebuild/xcrun, SwiftPM tools 6.2, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-10-in-repo-dependency-patching-design.md`

## Global Constraints

- Public repo: no credentials, tokens, or private paths in committed files or CI logs.
- Ghostty pin: `53e55147bbbb0157672dac0228aa7744e881f1fa` (`https://github.com/ghostty-org/ghostty`).
- Zig pin: `0.17.0`, verified against SHA-256 values committed in `deps/zig/checksums`.
- Patch series = the fork's 13 `Paging/*.patch` in `recipe.json` order at fork commit `8f9f75b63cb7af818b08b10c6c3706aa4d4ab85c` (includes the scrollback repair). Lakr's `Patches/ghostty/*` are not applied by the production build and are not imported.
- Patches are `git format-patch --zero-commit --no-signature --no-stat --full-index -k` output, ordered by `deps/ghostty/patches/.patches`, applied with `git am -3`.
- Wire codec stays `ghostty-8af6897c-paging-1`; SSH subsystem stays `terminal-paged-v1@graftty.dev`.
- Absorbed Swift: `GhosttyKit`, `GhosttyTerminal` (+ their resources), MIT license and credit to Lakr233 retained. Not imported: `ShellCraftKit`, `GhosttyTheme`.
- Local builds go through `scripts/swiftpm`; never `pkill` shared swift-test processes.
- macOS/iOS test jobs stay on hosted `xcode-27`; one `native-deps` job runs on `[self-hosted, macOS, ARM64]` for same-repo events and on hosted `macos-26` for fork PRs.
- Release rebuilds natives from source and uploads `native-deps-record.json`.

## Review Focus

1. Interrupted or concurrent `prepare` in two worktrees: the second must wait on the lock and never see a half-written artifact (atomic rename) — test in Task 2.
2. Stale `.deps` link after a patch edit: changing any patch file must change the key and force a rebuild, not reuse — test in Task 2.
3. A patch that no longer applies: `checkout`/`prepare` must fail naming the patch file, leaving no partial source dir under the key — test in Task 2.
4. Zig download with a wrong checksum: must fail and leave no installed toolchain — test in Task 1.
5. Prepared macOS-only framework, then an iOS build: `prepare --platforms macos,ios` must rebuild rather than reuse the macOS-only artifact — test in Task 2.

---

### Task 1: Zig pin and fetcher

**Files:**
- Create: `deps/zig/VERSION` (`0.17.0`), `deps/zig/checksums` (lines `<host> <sha256> <tarball-url>` for `aarch64-macos`, `x86_64-macos`, `x86_64-linux`, `aarch64-linux`), `deps/zig/patches/0.17.0-ios-visionos-std.patch` (copied from fork `Patches/zig/`), `scripts/deps-lib/zig.sh`
- Modify: `scripts/linux/install-zig.sh` (use `deps/zig/checksums`, not index.json's hash), `scripts/bump-zmx.sh`, `scripts/linux/build-zmx.sh`, `scripts/linux/test-packaging.py` (read `deps/zig/VERSION`); delete `scripts/zmx/ZIG_VERSION`
- Test: `scripts/test-deps.sh`

**Interfaces:**
- Produces: `deps_zig_path` (bash function; prints absolute path of a `zig` binary of the pinned version, downloading into `$GRAFTTY_DEPS_CACHE/zig/<version>-<host>` on first use); `deps_zig_lib_ios` (prints a staged patched std dir for iOS targets). `GRAFTTY_DEPS_CACHE` defaults to `~/Library/Caches/Graftty/deps` (macOS) or `${XDG_CACHE_HOME:-~/.cache}/graftty/deps` (Linux).

- [ ] Step 1: In `scripts/test-deps.sh`, add `test_zig_checksum_mismatch`: point `GRAFTTY_DEPS_ZIG_CHECKSUMS` at a temp file with a wrong hash and a `file://` tarball; assert `deps_zig_path` exits non-zero and the install dir does not exist.
- [ ] Step 2: Run `scripts/test-deps.sh`; expect FAIL (function missing).
- [ ] Step 3: Implement `scripts/deps-lib/zig.sh` (download to temp, `shasum -a 256 -c`, extract, atomic `mv`; reuse if `zig version` matches). Fill `checksums` from `https://ziglang.org/download/index.json` for 0.17.0 and cross-check the local `~/.local/zig/0.17.0` tarball hash for `aarch64-macos`.
- [ ] Step 4: Run `scripts/test-deps.sh`; expect PASS. Run `bash scripts/linux/install-zig.sh` logic review + `python3 -B scripts/linux/test-packaging.py`.
- [ ] Step 5: Commit.

### Task 2: Patch-series driver (`scripts/deps`)

**Files:**
- Create: `scripts/deps` (subcommands `key`, `checkout`, `export`, `prepare`), `scripts/deps-lib/series.sh`, `deps/ghostty/UPSTREAM_COMMIT`, `deps/ghostty/UPSTREAM_URL`
- Modify: `.gitignore` (add `.deps/`, drop `.dependencies/`)
- Test: `scripts/test-deps.sh`

**Interfaces:**
- `scripts/deps key ghostty [--platforms csv]` → prints 64-hex key = sha256 over: dependency name, UPSTREAM_COMMIT, every file under `deps/ghostty/` and `deps/zig/`, `scripts/deps`, `scripts/deps-lib/*`, sorted platform set.
- `scripts/deps checkout ghostty <dir>` → clone from the cached mirror (`$GRAFTTY_DEPS_CACHE/mirrors/ghostty.git`, fetched on demand), detach at UPSTREAM_COMMIT, `git am -3` each patch in `.patches` order. On failure: print `patch failed: <file>` and exit 1 (leave the checkout for conflict resolution).
- `scripts/deps export ghostty <dir>` → rewrite `deps/ghostty/patches/*.patch` and `.patches` from `UPSTREAM_COMMIT..HEAD` in `<dir>` (format flags from Global Constraints; filenames `NNNN-<subject-slug>.patch`).
- `scripts/deps prepare [ghostty|zmx|all] [--platforms csv] [--rebuild] [--record file]` → ensure `$GRAFTTY_DEPS_CACHE/ghostty/<key>/GhosttyKit.xcframework` exists (build under the cache lock into `<key>.tmp.$$`, then `mv`), then point `.deps/GhosttyKit.xcframework` (symlink) at it and write `.deps/ghostty.key`. Reuse a cached key whose platform set ⊇ requested. Builder is `$GRAFTTY_DEPS_GHOSTTY_BUILDER` (test seam) or Task 3's build script.
- Lock: `lockf` (macOS) / `flock` (Linux) on `$GRAFTTY_DEPS_CACHE/deps.lock`, like `scripts/swiftpm`.

- [ ] Step 1: Add tests to `scripts/test-deps.sh` using a throwaway upstream repo (file URL via `GRAFTTY_DEPS_GHOSTTY_URL` override) and a fake builder that writes a marker file:
  - `test_checkout_export_roundtrip`: checkout, amend a commit, export → patch file content changes; `.patches` order preserved.
  - `test_patch_failure_names_patch` (Review Focus 3).
  - `test_key_changes_with_patch` (Review Focus 2).
  - `test_concurrent_prepare_builds_once` (Review Focus 1): two background `prepare` runs → builder invoked once, both `.deps` links valid.
  - `test_platform_superset_reuse` (Review Focus 5): `macos,ios` after `macos` rebuilds; `macos` after `macos,ios` reuses.
- [ ] Step 2: Run; expect FAIL.
- [ ] Step 3: Implement `scripts/deps` and `scripts/deps-lib/series.sh`.
- [ ] Step 4: Run `scripts/test-deps.sh`; expect all PASS.
- [ ] Step 5: Commit.

### Task 3: Import the Ghostty series and build script

**Files:**
- Create: `deps/ghostty/patches/.patches` + 13 `NNNN-*.patch`; `deps/ghostty/package-patches/aro-blocks.patch` (diff form of fork `Paging/patch-zig-packages.py` edit); `deps/ghostty/build.sh` (port of fork `Script/build-ghostty.sh` + `build-platform.sh` + `merge-xcframework.sh` + `verify-xcframework.sh`, macos and ios groups only, using `deps_zig_path`/`deps_zig_lib_ios`); `deps/ghostty/support/libcxx-verbose-abort-compat.c`; `deps/ghostty/LICENSE-libghostty-spm` (Lakr233 MIT)
- Test: `deps/ghostty/tests/` ← fork `Paging/{production-surface-probe.m,probe.c,make-fixture.c,make-link-fixture.c,link-click-probe.m,SurfaceProbe-Info.plist,test-core.sh,production-test-surfaces.sh,test-link-clicks.sh}`, fork `Script/check-licenses.sh`; `scripts/deps test ghostty` runs them against `.deps`.

**Interfaces:**
- Consumes: Task 2 `checkout`, Task 1 zig helpers.
- Produces: `deps/ghostty/build.sh <source-dir> <platforms-csv> <out-dir>` → `<out-dir>/GhosttyKit.xcframework` with slices `macos-arm64_x86_64` and, for ios, `ios-arm64` + `ios-arm64_x86_64-simulator`; `scripts/deps test ghostty` → runs test-core, surfaces probe, `zig build test-lib-vt -Dtest-filter=snapshot.snapshot`, license check.

- [ ] Step 1: Convert: in a scratch clone at 53e55147, apply each fork patch in `recipe.json` order as a commit (subject = patch name); `scripts/deps export ghostty <clone>`.
- [ ] Step 2: Equivalence: `scripts/deps checkout ghostty /tmp/a`; diff its tree against the fork stack applied to a clean 53e55147 (`git diff --no-index`); expect no difference.
- [ ] Step 3: Port build scripts; `scripts/deps prepare ghostty --platforms macos`; expect xcframework with `x86_64 arm64` in `lipo -archs`.
- [ ] Step 4: `scripts/deps test ghostty`; expect AppKit surfaces 16 PASS, core 6, lib-vt 119/119, licenses OK.
- [ ] Step 5: Commit.

### Task 4: Absorb GhosttyKit/GhosttyTerminal and switch Package.swift

**Files:**
- Create: `Sources/GhosttyKit/`, `Sources/GhosttyTerminal/` (from fork at 8f9f75b6, with `LICENSE` header note), `Tests/GhosttyTerminalTests/` (fork `Tests/GhosttyKitTest` minus ShellCraft/Theme tests)
- Modify: `Package.swift` (tools 6.2; `swiftLanguageModes: [.v5]` package-wide; absorbed targets get `.swiftLanguageMode(.v6)` + the fork's four upcoming features; `.binaryTarget(name: "libghostty", path: ".deps/GhosttyKit.xcframework")`; add `Lakr233/DisplayLink` from 3.0.1 to `appleDependencies`; products `package: "libghostty-spm"` → local targets; remove `publishedGhosttyRevision`, `PagingBuild`, `compatibleRenderer`, `localGhosttyPath`, `GRAFTTY_GHOSTTY_PACKAGE_PATH`; `rendererIdentity` = contents of `.deps/ghostty.key`; add absorbed targets to `appleTargets`), `Package.resolved`, `scripts/swiftpm` (run `scripts/deps prepare ghostty --platforms macos` before swift on Darwin), `scripts/bundle.sh` (same), `scripts/ghostty-paging/*` (delete `test-package-selection.py`, `BUILD.md`; README points to `deps/`), `Sources/GrafttyKit/GhosttyResources/ghostty/PROVENANCE.md`, source comments naming libghostty-spm, `AGENTS.md` (Ghostty section)
- Test: existing suites.

- [ ] Step 1: `scripts/swiftpm build --build-tests`; expect success with no warnings.
- [ ] Step 2: `scripts/swiftpm test` filtered to `MacPaged|Ghostty|SnapshotCanvas|TerminalController`; then full `scripts/swiftpm test` (background, bounded timeout); expect pass except known flakes listed in memory.
- [ ] Step 3: iOS simulator compile of GrafttyMobile after `scripts/deps prepare ghostty --platforms macos,ios` + `xcodegen generate` (command from `project_ci_swift_older_than_local` memory).
- [ ] Step 4: `uv run scripts/generate-specs.py`; commit.

### Task 5: zmx through the shared cache

**Files:**
- Create: `scripts/deps-lib/zmx.sh` (builds `scripts/zmx/UPSTREAM_COMMIT` + patches universal binary; writes `VERSION`, `CHECKSUMS`)
- Modify: `scripts/deps` (`prepare zmx` → `.deps/zmx/{zmx,VERSION,CHECKSUMS}`), `scripts/bump-zmx.sh` (becomes compatibility check against the previous release's `zmx` extracted from the latest GitHub release asset; no binary write), `scripts/bundle.sh`, tests referencing `Resources/zmx-binary` (`Tests/GrafttyKitTests/Zmx/*`, `Tests/GrafttyTests/Terminal/MacPaged*Tests.swift`), `Tests/GrafttyTests/Specs/ZmxTodo.swift` (ZMX-1.3 text → `.deps/zmx`), Package.swift/Sources only if they read `Resources/zmx-binary`; delete `Resources/zmx-binary/`
- Test: `scripts/test-deps.sh` `test_zmx_key_inputs`; existing Zmx integration tests.

- [ ] Step 1: Grep every `zmx-binary` reference; switch to `.deps/zmx`.
- [ ] Step 2: `scripts/deps prepare zmx`; `lipo -archs .deps/zmx/zmx` = `x86_64 arm64`; `.deps/zmx/zmx --version` matches `VERSION`.
- [ ] Step 3: Run Zmx integration tests via `scripts/swiftpm test --filter Zmx`; expect pass.
- [ ] Step 4: Commit.

### Task 6: CI and release

**Files:**
- Modify: `.github/workflows/ci.yml` (new `native-deps` job: runner per Global Constraints; `scripts/deps prepare all --platforms macos,ios`; when the key was newly built run `scripts/deps test ghostty`; upload `.deps` as artifact `native-deps`, following symlinks; `macos-build-and-test` and `ios-test-shards` `needs: native-deps`, download into `.deps`, and keep their own cache keys hashing `deps/**` instead of `scripts/ghostty-paging/**`), `.github/actions/paging-renderer/action.yml` (drop the override env; keep `GRAFTTY_RENDERER_CONTEXT` and `GRAFTTY_REQUIRE_PAGED_HISTORY`), `.github/workflows/agent-integration.yml`, `.github/workflows/release.yml` (`scripts/deps prepare all --platforms macos --rebuild --record native-deps-record.json` before `bundle.sh`; upload record with the release), `.github/workflows/linux.yml` only if it reads `scripts/zmx/ZIG_VERSION`
- Test: `python3 -B scripts/ci/test_test_plan.py`; `actionlint` if installed.

- [ ] Step 1: Edit workflows; validate YAML parses (`ruby -ryaml` or `python3 -c yaml`).
- [ ] Step 2: Commit; CI on the PR is the real test.

### Task 7: Update recipe, docs, archive note

**Files:**
- Modify: `AGENTS.md` (new "Updating dependencies" section: the biweekly recipe — `scripts/deps checkout`, move pin, resolve `git am -3` conflicts as commits, `scripts/deps export`, `scripts/deps test ghostty`, `scripts/swiftpm test`, Swift package bumps via `swift package update`, one PR with upstream ranges and gate results), `scripts/zmx/README.md`, `scripts/ghostty-paging/README.md`, `deps/README.md` (layout, Electron-style series, cache, licenses)

- [ ] Step 1: Write docs; commit.
- [ ] Step 2: `/code-review xhigh --fix`; `/simplify`; push; open PR; watch CI to green.
