# Vendor Ghostty Runtime Resources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship ghostty's shell-integration scripts and `xterm-ghostty` terminfo inside Graftty's own bundle so OSC 7/133 shell integration no longer depends on a separately installed Ghostty.app.

**Architecture:** Vendored payload (extracted from the official Ghostty 1.2.2 dmg — the ghostty version backing libghostty-spm) is declared as SPM resources on the GrafttyKit target, flowing into the existing `*_GrafttyKit.bundle` that `bundle.sh` already ships. A new pure `GhosttyRuntimeResources` helper in GrafttyKit implements the resolution precedence (env override → bundled → warn), and `TerminalManager` calls it before `ghostty_init` instead of probing `/Applications/Ghostty.app`.

**Tech Stack:** Swift 6 / SPM resources / Swift Testing. Spec convention: `@spec` EARS titles per CLAUDE.md; run `scripts/generate-specs.py` after spec changes.

**Design spec:** `docs/superpowers/specs/2026-06-03-vendor-ghostty-resources-design.md`

---

### Task 1: Vendor the payload and declare SPM resources

Data + build-config task (no behavioral test yet — tests can only see the
payload through a GrafttyKit API, which Task 2 adds; Task 2's CONFIG-2.5
guard test is the permanent CI check for this payload).

**Files:**
- Create: `Sources/GrafttyKit/GhosttyResources/ghostty/shell-integration/**` (vendored)
- Create: `Sources/GrafttyKit/GhosttyResources/ghostty/PROVENANCE.md`
- Create: `Sources/GrafttyKit/GhosttyResources/terminfo/**` (vendored)
- Modify: `Package.swift` (GrafttyKit target `resources:` array, around line 63)

- [ ] **Step 1: Download and verify the official Ghostty 1.2.2 dmg**

```bash
curl -fLo /tmp/Ghostty-1.2.2.dmg https://release.files.ghostty.org/1.2.2/Ghostty.dmg
shasum -a 256 /tmp/Ghostty-1.2.2.dmg
```

Record the printed SHA-256 — it goes into `PROVENANCE.md` in Step 3.

- [ ] **Step 2: Mount and copy the two payload directories**

Run from the repo root (`/Users/btucker/projects/graftty/.worktrees/path-ordering`):

```bash
MOUNT=$(hdiutil attach -nobrowse -readonly /tmp/Ghostty-1.2.2.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')
# Sanity: must print 1.2.2 — abort if not.
defaults read "$MOUNT/Ghostty.app/Contents/Info.plist" CFBundleShortVersionString
mkdir -p Sources/GrafttyKit/GhosttyResources/ghostty
cp -R "$MOUNT/Ghostty.app/Contents/Resources/ghostty/shell-integration" \
      Sources/GrafttyKit/GhosttyResources/ghostty/shell-integration
cp -R "$MOUNT/Ghostty.app/Contents/Resources/terminfo" \
      Sources/GrafttyKit/GhosttyResources/terminfo
hdiutil detach "$MOUNT"
```

Only `shell-integration` is copied from the `ghostty/` dir — NOT `themes/`
or `doc/` (~MBs of content Graftty doesn't read; libghostty themes come from
the SPM package).

Verify the copy:

```bash
ls Sources/GrafttyKit/GhosttyResources/ghostty/shell-integration   # bash elvish fish zsh (1.2.2 has no nushell)
ls Sources/GrafttyKit/GhosttyResources/terminfo/78                  # xterm-ghostty
head -3 Sources/GrafttyKit/GhosttyResources/ghostty/shell-integration/zsh/.zshenv  # GPLv3 header present
```

- [ ] **Step 3: Write the provenance record**

Create `Sources/GrafttyKit/GhosttyResources/ghostty/PROVENANCE.md` (replace
`<sha256>` with the Step 1 hash):

```markdown
# Vendored Ghostty Runtime Resources — Provenance

| | |
|---|---|
| Upstream | https://github.com/ghostty-org/ghostty |
| Version | 1.2.2 (tag `v1.2.2`) |
| Artifact | https://release.files.ghostty.org/1.2.2/Ghostty.dmg |
| Artifact SHA-256 | `<sha256>` |
| Extracted | `Ghostty.app/Contents/Resources/ghostty/shell-integration` → `ghostty/shell-integration`; `Ghostty.app/Contents/Resources/terminfo` → `terminfo` (sibling, mirroring Ghostty.app's layout) |
| Copied | 2026-06-03 |

## Why 1.2.2

The payload must match the ghostty source version backing our libghostty:
`btucker/libghostty-spm` (branch `expose-selection-api`) pins its binary
target to Lakr233's `storage.1.2.2` artifact, built from ghostty v1.2.2.

## Update procedure

When `libghostty-spm` moves to a new ghostty version:
1. Download `https://release.files.ghostty.org/<ver>/Ghostty.dmg`.
2. Re-extract both directories exactly as above (see the design doc
   `docs/superpowers/specs/2026-06-03-vendor-ghostty-resources-design.md`).
3. Update this file's version/SHA/date.
4. `swift test` — the CONFIG-2.5 payload-guard test validates the layout.

## Licensing

These files are redistributed verbatim as **mere aggregation** — separate
data files, never linked into Graftty's binaries. The zsh and bash
integrations are GPLv3 (derived from Kitty's); their license headers are
preserved in-file, exactly as Ghostty.app (MIT) distributes them. The
remaining scripts and the terminfo entry carry ghostty's MIT license.
```

- [ ] **Step 4: Declare the SPM resources**

In `Package.swift`, GrafttyKit target — change:

```swift
            resources: [
                .copy("Web/Resources"),
            ],
```

to:

```swift
            resources: [
                .copy("Web/Resources"),
                // Vendored ghostty runtime resources (CONFIG-2.5) — see
                // GhosttyResources/ghostty/PROVENANCE.md. `ghostty` and
                // `terminfo` land at the bundle root as siblings, mirroring
                // Ghostty.app's Contents/Resources layout, which is what
                // ZmxSpawnConfiguration.availableGhosttyTerminfoDir probes.
                .copy("GhosttyResources/ghostty"),
                .copy("GhosttyResources/terminfo"),
            ],
```

(`PROVENANCE.md` lives inside `GhosttyResources/ghostty/`, so it travels with
the first `.copy` and SPM emits no unhandled-resource warning.)

- [ ] **Step 5: Build and verify the bundle layout**

```bash
swift build 2>&1 | tail -3        # must succeed, no "unhandled resource" warnings
ls .build/debug/*_GrafttyKit.bundle/
```

Expected: the bundle listing now contains `ghostty` and `terminfo` (alongside
the pre-existing `Resources` dir from Web/Resources).

```bash
ls .build/debug/*_GrafttyKit.bundle/ghostty/shell-integration/zsh/.zshenv
ls .build/debug/*_GrafttyKit.bundle/terminfo/78/xterm-ghostty
```

Both must exist.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/GhosttyResources Package.swift
git commit -m "feat(CONFIG-2.5): vendor ghostty 1.2.2 shell-integration + terminfo into GrafttyKit resources"
```

---

### Task 2: GhosttyRuntimeResources helper (TDD)

**Files:**
- Create: `Tests/GrafttyKitTests/GhosttyRuntimeResourcesTests.swift`
- Create: `Sources/GrafttyKit/GhosttyRuntimeResources.swift`
- Modify: `Tests/GrafttyTests/Specs/ConfigTodo.swift` (delete the CONFIG-2.2/2.3/2.4 inventory entries — lines 31–44)

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/GhosttyRuntimeResourcesTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("GhosttyRuntimeResources — vendored payload")
struct GhosttyVendoredPayloadTests {
    @Test("""
    @spec CONFIG-2.5: The application bundle shall include ghostty's per-shell integration scripts and the `xterm-ghostty` terminfo entry as vendored resources, pinned to the ghostty version backing libghostty-spm, with upstream license headers preserved and a provenance record, so shell integration works without a separately installed Ghostty.app.
    """)
    func vendoredPayloadShipsInModuleBundle() throws {
        let dir = try #require(GhosttyRuntimeResources.bundledResourcesDir())
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("shell-integration/zsh/.zshenv").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("shell-integration/bash/ghostty.bash").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("PROVENANCE.md").path))
        // terminfo must sit as a SIBLING of the ghostty dir — the layout
        // ZmxSpawnConfiguration.availableGhosttyTerminfoDir (ZMX-6.5) probes.
        let terminfo = dir.deletingLastPathComponent().appendingPathComponent("terminfo")
        #expect(fm.fileExists(atPath: terminfo.appendingPathComponent("78/xterm-ghostty").path))
    }
}

@Suite("GhosttyRuntimeResources.resolve — precedence")
struct GhosttyRuntimeResourcesResolveTests {
    private let bundled = URL(fileURLWithPath: "/bundle/ghostty", isDirectory: true)

    @Test("""
    @spec CONFIG-2.2: If `GHOSTTY_RESOURCES_DIR` is already set and non-empty in the process environment, the application shall not override it; the user's explicit setting wins.
    """)
    func envOverrideWins() {
        let r = GhosttyRuntimeResources.resolve(
            processEnv: ["GHOSTTY_RESOURCES_DIR": "/custom/ghostty"],
            bundledDir: bundled
        )
        #expect(r == .environmentOverride("/custom/ghostty"))
    }

    @Test("""
    @spec CONFIG-2.3: Otherwise, the application shall set `GHOSTTY_RESOURCES_DIR` to the `ghostty` directory vendored in GrafttyKit's resource bundle (per CONFIG-2.5), so shell integration does not depend on a separately installed Ghostty.app.
    """)
    func unsetEnvUsesBundledCopy() {
        let r = GhosttyRuntimeResources.resolve(processEnv: [:], bundledDir: bundled)
        #expect(r == .bundled("/bundle/ghostty"))
    }

    @Test func emptyEnvValueUsesBundledCopy() {
        let r = GhosttyRuntimeResources.resolve(
            processEnv: ["GHOSTTY_RESOURCES_DIR": ""],
            bundledDir: bundled
        )
        #expect(r == .bundled("/bundle/ghostty"))
    }

    @Test("""
    @spec CONFIG-2.4: If the vendored ghostty resources are missing from the application bundle, the application shall log a warning identifying the problem and continue with shell-integration features (OSC 7 auto-reporting, OSC 133 prompt marks, `COMMAND_FINISHED`, and `PROGRESS_REPORT`) unavailable; spawned shells shall still function.
    """)
    func missingPayloadResolvesUnavailable() {
        let r = GhosttyRuntimeResources.resolve(processEnv: [:], bundledDir: nil)
        #expect(r == .unavailable)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter GhosttyRuntimeResources 2>&1 | tail -5
```

Expected: **compile error** — `cannot find 'GhosttyRuntimeResources' in scope`.
(A compile error is the RED state here; the type doesn't exist yet.)

- [ ] **Step 3: Write the implementation**

Create `Sources/GrafttyKit/GhosttyRuntimeResources.swift`:

```swift
import Foundation

/// Resolves the `GHOSTTY_RESOURCES_DIR` value libghostty reads at
/// `ghostty_init` time and spawn paths propagate to shells (CONFIG-2.x).
/// Graftty vendors ghostty's shell-integration scripts and terminfo into
/// GrafttyKit's SPM resource bundle (CONFIG-2.5,
/// `GhosttyResources/ghostty/PROVENANCE.md`), so resolution no longer
/// depends on a separately installed Ghostty.app.
public enum GhosttyRuntimeResources {
    /// How `GHOSTTY_RESOURCES_DIR` should be sourced. A pure decision value
    /// so the precedence rules are unit-testable without process-global
    /// `setenv` state.
    public enum Resolution: Equatable {
        /// CONFIG-2.2: the user's explicit env setting wins.
        case environmentOverride(String)
        /// CONFIG-2.3: point at the vendored copy in our bundle.
        case bundled(String)
        /// CONFIG-2.4: payload missing — caller warns, shells degrade
        /// gracefully (no OSC 7/133, TERM falls back per ZMX-6.5).
        case unavailable
    }

    /// The vendored `ghostty` resources dir inside GrafttyKit's module
    /// bundle, or nil when the payload is missing (mis-declared resource,
    /// corrupt install). The `bundle` parameter is a test seam.
    public static func bundledResourcesDir(bundle: Bundle = .module) -> URL? {
        guard let url = bundle.url(forResource: "ghostty", withExtension: nil),
              FileManager.default.fileExists(
                  atPath: url.appendingPathComponent("shell-integration").path
              )
        else { return nil }
        return url
    }

    /// Pure precedence decision (CONFIG-2.2 → CONFIG-2.3 → CONFIG-2.4).
    public static func resolve(
        processEnv: [String: String],
        bundledDir: URL?
    ) -> Resolution {
        if let existing = processEnv["GHOSTTY_RESOURCES_DIR"], !existing.isEmpty {
            return .environmentOverride(existing)
        }
        guard let bundledDir else { return .unavailable }
        return .bundled(bundledDir.path)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter GhosttyRuntimeResources 2>&1 | tail -5
```

Expected: all 5 tests PASS (the payload-guard test passes because Task 1
vendored the files).

- [ ] **Step 5: Delete the superseded inventory entries**

In `Tests/GrafttyTests/Specs/ConfigTodo.swift`, delete the three
`@Test(..., .disabled("not yet implemented"))` entries for `config_2_2`,
`config_2_3`, and `config_2_4` (lines 31–44) — their spec IDs now live on the
real tests above with updated EARS text. Keep `config_2_1` (still
unimplemented inventory). The file ends:

```swift
    @Test("""
@spec CONFIG-2.1: Before calling `ghostty_init`, the application shall set the `GHOSTTY_RESOURCES_DIR` environment variable so libghostty can locate its per-shell integration scripts.
""", .disabled("not yet implemented"))
    func config_2_1() async throws { }
}
```

- [ ] **Step 6: Verify no duplicate spec IDs**

```bash
scripts/generate-specs.py
```

Expected: succeeds (it fails loudly if CONFIG-2.2/2.3/2.4 appear both active
and disabled). Do NOT commit SPECS.md yet — Task 4 regenerates and commits it
once all spec changes land.

```bash
git checkout SPECS.md
```

- [ ] **Step 7: Commit**

```bash
git add Tests/GrafttyKitTests/GhosttyRuntimeResourcesTests.swift Sources/GrafttyKit/GhosttyRuntimeResources.swift Tests/GrafttyTests/Specs/ConfigTodo.swift
git commit -m "feat(CONFIG-2.2/2.3/2.4): GhosttyRuntimeResources resolution helper — bundled copy replaces Ghostty.app probing"
```

---

### Task 3: Wire TerminalManager to the bundled resources

**Files:**
- Modify: `Sources/Graftty/Terminal/TerminalManager.swift` (the
  `pointAtGhosttyResourcesIfAvailable` function, around lines 904–924, and
  its call site in `initialize()` around line 327)

- [ ] **Step 1: Replace the resolver function**

In `Sources/Graftty/Terminal/TerminalManager.swift`, replace this entire
function (lines ~904–924):

```swift
    /// If `GHOSTTY_RESOURCES_DIR` isn't already set and Ghostty.app is
    /// installed, borrow its resources directory. Respects an existing
    /// value (user overrides from the shell environment win) and respects
    /// the user's choice to install Ghostty elsewhere by walking a couple
    /// of standard locations before giving up.
    private static func pointAtGhosttyResourcesIfAvailable() {
        if let existing = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
           !existing.isEmpty {
            return
        }
        let candidates = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
            (NSHomeDirectory() as NSString).appendingPathComponent(
                "Applications/Ghostty.app/Contents/Resources/ghostty"
            ),
        ]
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return
        }
        setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
    }
```

with:

```swift
    /// Resolve `GHOSTTY_RESOURCES_DIR` before `ghostty_init` (CONFIG-2.x).
    /// An explicit env setting wins (CONFIG-2.2); otherwise point at the
    /// copy vendored in GrafttyKit's resource bundle (CONFIG-2.3/2.5) so
    /// shell integration never depends on a separately installed
    /// Ghostty.app. libghostty reads the variable to locate its
    /// shell-integration scripts; `ZmxSpawnConfiguration` and `WebSession`
    /// read it when constructing spawn environments.
    private static func pointAtGhosttyResources() {
        switch GhosttyRuntimeResources.resolve(
            processEnv: ProcessInfo.processInfo.environment,
            bundledDir: GhosttyRuntimeResources.bundledResourcesDir()
        ) {
        case .environmentOverride:
            break
        case .bundled(let dir):
            setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
        case .unavailable:
            // CONFIG-2.4: warn visibly (not today's silent skip) and
            // degrade gracefully — shells still work, OSC 7/133-driven
            // features go quiet, TERM falls back per ZMX-6.5.
            NSLog("graftty: vendored ghostty resources missing from GrafttyKit bundle; shell integration disabled")
        }
    }
```

- [ ] **Step 2: Update the call site**

In `initialize()` (around line 327), change:

```swift
        Self.pointAtGhosttyResourcesIfAvailable()
```

to:

```swift
        Self.pointAtGhosttyResources()
```

Also update the comment block directly above it (lines ~319–326) — replace:

```swift
        // Point libghostty at a resources directory BEFORE `ghostty_init`.
        // It reads `GHOSTTY_RESOURCES_DIR` to locate shell-integration
        // scripts (zsh hooks that emit OSC 7 for PWD changes, OSC 133 for
        // prompt marks, etc.). libghostty-spm doesn't ship these, so
        // without this Graftty shells are "dumb" — no auto-PWD reporting,
        // no prompt integration. Borrow them from Ghostty.app if the user
        // has it installed; silently skip otherwise (shells still work,
        // just without integration features).
```

with:

```swift
        // Point libghostty at a resources directory BEFORE `ghostty_init`.
        // It reads `GHOSTTY_RESOURCES_DIR` to locate shell-integration
        // scripts (zsh hooks that emit OSC 7 for PWD changes, OSC 133 for
        // prompt marks, etc.). libghostty-spm doesn't ship these, so
        // Graftty vendors them in GrafttyKit's resource bundle
        // (CONFIG-2.5) and points the env at that copy unless the user
        // set an explicit override.
```

- [ ] **Step 3: Build and run the full test suite**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: build succeeds; all tests pass (~2015+ tests). If
`GhosttyVendoredPayloadTests` fails here, the Package.swift resource
declaration from Task 1 regressed — fix there, not in this task.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Terminal/TerminalManager.swift
git commit -m "feat(CONFIG-2.3): TerminalManager resolves ghostty resources from the vendored bundle, drops Ghostty.app probing"
```

---

### Task 4: Regenerate SPECS.md and end-to-end verification

**Files:**
- Modify: `SPECS.md` (generated — never hand-edit)

- [ ] **Step 1: Regenerate SPECS.md**

```bash
scripts/generate-specs.py
git diff SPECS.md | head -40
```

Expected diff: CONFIG-2.2 unchanged text but no longer marked pending;
CONFIG-2.3 / CONFIG-2.4 with the new EARS text; CONFIG-2.5 added.

- [ ] **Step 2: Full test suite**

```bash
swift test 2>&1 | tail -3
```

Expected: all pass.

- [ ] **Step 3: Bundle smoke test (local, not CI)**

```bash
CONFIGURATION=debug ./scripts/bundle.sh 2>&1 | tail -3
ls .build/Graftty.app/Contents/Resources/*_GrafttyKit.bundle/ghostty/shell-integration/zsh/.zshenv
ls .build/Graftty.app/Contents/Resources/*_GrafttyKit.bundle/terminfo/78/xterm-ghostty
```

Both `ls` calls must succeed — proving the payload rides the existing
bundle-copy glob into the .app.

- [ ] **Step 4: Commit**

```bash
git add SPECS.md
git commit -m "docs: regenerate SPECS.md for CONFIG-2.x vendored-resources specs"
```

---

## Out of scope (do not do)

- No changes to `scripts/bundle.sh` (the existing `*_GrafttyKit.bundle` glob
  already ships the payload — that's the point of attaching to GrafttyKit).
- No changes to `ZmxSpawnConfiguration`, `WebSession`, `SurfaceHandle`, or
  `AgentHookInstaller` — they consume `GHOSTTY_RESOURCES_DIR` / spawn-env
  values that this plan only changes the *source* of.
- No `WebSession` agent-hooks env propagation (separate known gap).
- No vendoring of ghostty `themes/` or `doc/`.
