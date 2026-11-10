# In-repo dependency patching

Status: draft for approval. Date: 2026-11-10.

## Intent

Graftty's dependencies should be updated routinely: an agent opens one PR about
every two weeks, and Ben reviews it. Today each patched dependency is maintained
differently, so every update starts with archaeology:

- **libghostty** comes from `btucker/libghostty-spm`, a fork of
  `Lakr233/libghostty-spm`, which itself wraps Ghostty. The fork carries Lakr's
  18 Ghostty patches and Zig patch, about 1,460 lines of our changes to Lakr's
  Swift sources and patches, and our own `Paging/` patch series and probes. A
  change ships through a build number, a two-stage `build.yml` → `release.yml`
  publication, a storage tag, provenance receipts, and a revision pin plus
  local-override verifier in Graftty's `Package.swift`.
- **zmx** is already an upstream pin plus patches in this repo
  (`scripts/zmx/`), but `scripts/bump-zmx.sh` commits the built 5 MB binary to
  `Resources/zmx-binary/`.
- **Swift packages** are ordinary SwiftPM version pins.

The November 2026 update illustrates the cost. Moving Ghostty from 83fb9562 to
53e55147 took five PRs across two repositories, a staging release, an outage
wait, and a wrong-baseline mistake (fork `main` was not the Ghostty Graftty
shipped). A scrollback regression fix still needed a separate fork PR and
publication afterwards.

## Decisions made

These were decided in conversation and are not open to the builder:

1. **No forks.** Each patched upstream (Ghostty, zmx) is represented in this
   repo by a pin to an exact, unmodified upstream commit plus an ordered patch
   series.
2. **Absorb Lakr's layer.** Copy Lakr's Ghostty patches, Zig patch, and the
   Swift sources Graftty uses (`GhosttyKit`, `GhosttyTerminal`, plus anything
   they depend on) into this repo once, with our changes already applied, and
   keep his MIT license and credit. After that we patch Ghostty directly and stop
   tracking his repository. Cherry-picking his later fixes by hand remains
   possible.
3. **Graftty builds its own native dependencies (option B).** There is no
   separately published libghostty or zmx artifact and no multi-part publish
   flow. Builds produce the frameworks/binaries from the pins and patches in the
   checked-out commit, behind a cache keyed on those inputs. Ben chose this
   because he dislikes multi-part builds.
4. **Zig is downloaded automatically.** On first use the build tooling
   downloads the exact pinned Zig release and verifies it against a checksum
   committed in this repo.
5. **One PR per update cycle.** Pin moves, patch refreshes, Swift migrations,
   and wire-format changes for a cycle land together.
6. **Hybrid CI.** One dependency-build job runs on the self-hosted runner
   (mini-m1) with a persistent on-disk cache and hands the built artifacts to
   the hosted test jobs (`xcode-27`), which stay hosted so Mac and iOS tests do
   not queue on mini-m1. Only that job queues, and only pin/patch/build-script
   changes make it do real work.
7. **Releases rebuild from source.** The release job builds libghostty and zmx
   from the tag's pins and patches (no cache restore) and attaches a small
   build record (input and output hashes) to the release.
8. **The update is a recipe, not a schedule.** A script plus agent
   instructions; Ben asks an agent to "update dependencies" and it opens the
   PR. No stored credentials or scheduler. Scheduling may come later.

## Goals

- A biweekly update is one agent-authored PR in this repo that Ben can review:
  pin diffs, patch diffs, Swift changes, and gate results.
- Upstream changes and our changes are always separable in review: the pin says
  which upstream commit; the patch files say what we change.
- A fresh clone builds and tests with one command on macOS, without manually
  installing Zig.
- The shipped app is built from exactly the pins and patches of the tagged
  commit.
- Patch rot is reported precisely: which patch failed to apply, against which
  upstream commit.

## Non-goals

- Changing ordinary SwiftPM dependencies (Sparkle, WebRTC, swift-nio-ssh, …).
  They stay version pins; the biweekly PR bumps them in the same cycle.
- Upstreaming our patches to Ghostty or zmx (worth doing, separate effort).
- Changing the paged snapshot wire codec (`ghostty-8af6897c-paging-1`) or the
  SSH subsystem name.
- Windows support beyond what exists today.

## Anti-goals

- A second repository, release, or publish step that must happen before a
  Graftty PR can build.
- Committed build outputs that drift from their recorded inputs.
- Per-worktree multi-gigabyte build trees (this round filled the disk once).
- Any change that makes running zmx daemons from earlier releases incompatible
  (the existing `compatibility_test.py` N-1 and 0.5-floor checks must survive).

## Constraints

- **Public repo.** Nothing private or credential-bearing may be committed or
  emitted into logs.
- **SwiftPM `binaryTarget(path:)`** only accepts paths inside the package, so
  the built xcframework must be materialized (copy or symlink) at an in-repo,
  git-ignored path before SwiftPM resolves the package.
- **GrafttyMobile's Xcode project** consumes the root package through
  `XCLocalSwiftPackageReference "../.."`. Xcode cannot run our script before
  package resolution, so iOS developers need the dependency prepared first
  (one documented command), and iOS CI must run that step.
- **iOS CI is near its wall clock** (~14 of 15 minutes). A cold libghostty build
  must not land inside that budget; CI needs a warm cache or a separate,
  earlier step.
- **Shared SwiftPM wrapper.** Local builds go through `scripts/swiftpm`, which
  holds a global lock and a shared build tree under
  `~/Library/Caches/Graftty/SwiftPM`. The native dependency cache belongs
  beside it and must be safe under concurrent worktrees.
- **Linux** builds zmx from source already (`scripts/linux/build-zmx.sh`,
  `scripts/linux/install-zig.sh`) and does not link libghostty. Linux keeps
  working.
- **Release workflow** (`release.yml`) runs only `swift build` and
  `bundle.sh`; it must build the native dependencies itself (decision 7).
  `bundle.sh` currently copies `Resources/zmx-binary/zmx`.
- **Compatibility gate.** The checks that caught this round's problems must run
  in the update PR: snapshot golden fixtures, paged-terminal suites, the
  production surface probes (AppKit; UIKit where a simulator is available),
  Ghostty `test-lib-vt` snapshot tests, `test-core.sh`, license check, and zmx
  `compatibility_test.py`.
- Swift 6.3.3 in CI vs 6.4 locally; the Ghostty C header uses
  `assume_nonnull`.

## Shape of the solution

This is the established **patch series** (patch queue, "carried downstream
patches") pattern: Debian's `3.0 (quilt)` format, Homebrew/Nix/Yocto recipes,
and most directly Electron, which pins Chromium and Node in `DEPS` and carries
`git format-patch` files in `patches/<upstream>/` with an ordered `.patches`
list, updating Chromium every few weeks. Follow Electron's conventions:

- Pins are plain files (decided; not submodules or subtrees), one upstream
  commit per dependency.
- Patches are `git format-patch` output (with author, message, and index
  lines) listed in an explicit order file, applied with `git am -3` so most
  upstream moves merge automatically.
- A round-trip script applies the series to a checkout as commits and exports
  the edited commits back to patch files; the update agent resolves conflicts
  as ordinary git commits in between.

Proposed layout (names are the builder's to refine):

```
deps/
  zig/        VERSION, per-host SHA-256 checksums, fetch script
  ghostty/    UPSTREAM_COMMIT, patches/0001-….patch …, zig-patches/, build script
  zmx/        UPSTREAM_COMMIT, patches/, GRAFTTY_REVISION, LEGACY_* (moved from scripts/zmx)
Sources/GhosttyKit, Sources/GhosttyTerminal   (absorbed Swift, now Graftty targets)
```

- **Cache key** for each native artifact = hash of: upstream commit, every
  patch file, Zig version, the build scripts, and the target platform set.
  Changing how we build forces a rebuild.
- **Local cache** lives under `~/Library/Caches/Graftty/` and is shared by all
  worktrees, with atomic publish (build in a temp dir, rename into place) so
  concurrent worktrees never see half-written artifacts.
- `scripts/swiftpm` (and a standalone `scripts/deps prepare` for Xcode users)
  ensures the keyed artifact exists, building it if missing, then links it into
  the git-ignored in-repo path the package manifest references.
- **CI**: a `native-deps` job on mini-m1 computes the key, reuses its on-disk
  cache or builds on a miss, and uploads the artifacts for that key (workflow
  artifact). Hosted Mac/iOS test jobs depend on it and download the artifacts,
  so they never pay for a Zig build inside their timeouts. Today hosted
  `xcode-27` runs `macos-build-and-test` and `ios-test-shards` deliberately
  (see comments in `ci.yml`); that stays. Pull requests from forks cannot use
  the self-hosted runner; for them the job falls back to a hosted runner with
  `actions/cache` and may build cold. That is acceptable.
- **Release**: `release.yml` (hosted `macos-26`) builds the native
  dependencies from source with no cache restore, then attaches a build
  record (inputs hash list, output hashes) as a release asset. This replaces
  the fork's `PAGING-BUILD.json` provenance receipts.
- **Third-party Zig packages** (my call): fetched from their upstream URLs on
  cold builds. Zig verifies each package's content hash, so a vanished or
  altered package fails loudly; the fetch step retries and its error names the
  URL. CI caches Zig's package cache by key. Edits to fetched packages (today
  `Paging/patch-zig-packages.py` patches aro in place) become patch files in
  the Ghostty series's package layer and are cache-key inputs. No mirror.
- **zmx** stops committing its binary. It builds through the same mechanism;
  `bundle.sh` takes it from the cache. The N-1 compatibility test keeps working
  from a recorded previous release binary rather than a committed working-tree
  binary (builder decides the source, e.g. the previous GitHub release asset).
- **The update recipe** (a script plus agent instructions in `AGENTS.md`):
  move pins, reapply patches with three-way merging, report failing patches by
  name, regenerate patches from the result, run the gate, and open one PR whose
  body lists upstream ranges, patch changes, and gate results.
- **Package.swift** loses the remote libghostty-spm dependency, the revision
  pin, `PAGING-BUILD.json` verification, and `GRAFTTY_GHOSTTY_PACKAGE_PATH`
  override; the renderer identity used to bust Clang's module cache derives
  from the cache key instead.

## Migration

1. Absorb: import Lakr's patches and the fork's patches as one ordered series
   against Ghostty 53e55147, including the scrollback repair currently on
   `btucker/libghostty-spm#5` (`8f9f75b6`). Import the Swift sources from the
   fork at that commit.
2. Prove equivalence: the in-repo build of 53e55147 must produce a library with
   the same native source tree as the fork's build (diff the patched trees, as
   was done for PR #5) and pass the full gate.
3. Switch `Package.swift`, CI, `bundle.sh`, and `release.yml` to the in-repo
   build; move zmx to the shared mechanism and delete `Resources/zmx-binary/`.
4. Archive `btucker/libghostty-spm` (read-only, with a README pointer). Old
   Graftty tags keep resolving because their pinned revisions and release assets
   stay published.

Fork PR #5 may still be published from the fork first if a release is needed
before the migration lands; the migration imports the same patch either way.

## Calls made by the writer (check these)

- Upstream URLs for Zig packages, no mirror (above).
- Lakr's `.sh` anchored-edit patches become real diffs so they can be
  three-way merged; equivalence is proven with all of them applied, and unused
  ones (visionOS, Mac Catalyst, …) are removed afterwards in the same project.
- The package manifest moves to the Swift tools version the absorbed Swift 6
  targets need (the fork uses 6.2).
- The N-1 zmx binary for `compatibility_test.py` comes from the previous
  Graftty GitHub release asset instead of the committed working-tree binary.

## Left to the builder

- Directory and script names.
- Which of Lakr's 18 Ghostty patches and Swift sources Graftty actually needs
  (drop visionOS/Mac Catalyst/ShellCraftKit/theme pieces if unused).
- Which platform slices each command builds (e.g. macOS-only for
  `scripts/swiftpm test`, iOS slices for `scripts/deps prepare --ios`).
- How the probes, fixtures, and Python suites from the fork's `Paging/` are
  organized and which run on every PR versus only when pins or patches change.
- Cache eviction policy for old keys.
