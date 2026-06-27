# Vertical Sizing Merge Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the completed explicit display ownership and mobile vertical-sizing branch auditable and merge-ready.

**Architecture:** This is a hardening and evidence plan, not another architecture rewrite. The branch already routes resize/input authority through explicit display ownership and reserves mobile terminal height for bottom chrome; this plan verifies the implementation, fixes any spec/code contradictions, and records the remaining manual validation matrix.

**Tech Stack:** Swift 5.10, Swift Testing, SwiftUI/UIKit, NIO WebSocket, zmx attach, libghostty, Vite/Vitest, generated `SPECS.md`.

---

## Scope and Risks

- [ ] Do not add new ownership abstractions unless an audit finds a real correctness gap.
- [ ] Treat old `sizeLeader`, `serverGrid`, and legacy-only resize language as defects in current source/specs, not as harmless wording, because they reintroduce the implicit model.
- [ ] Keep legacy `resize` compatibility only where owner-gated by the new store.
- [ ] Do not hand-edit generated web resources or `SPECS.md`; update sources and run the generator/build scripts.
- [ ] Manual on-device validation remains necessary for the keyboard accessory row because unit tests cover the height math, not UIKit's live measurement timing.

## File Map

| Path | Responsibility |
| --- | --- |
| `docs/superpowers/plans/2026-06-21-explicit-display-ownership.md` | Original implementation plan; use as the source checklist for completed scope. |
| `docs/superpowers/specs/2026-06-21-explicit-display-ownership-design.md` | Design reference for explicit ownership and vertical sizing decisions. |
| `Sources/GrafttyProtocol/WebControlEnvelope.swift` | Owner-aware control envelope protocol plus legacy resize compatibility. |
| `Sources/GrafttyKit/SessionDisplayOwnershipStore.swift` | Process/shared owner state machine. |
| `Sources/GrafttyKit/Web/WebServer.swift` | Web bridge owner gate and legacy resize migration path. |
| `web-client/src/components/TerminalPane.tsx` | Browser owner/follower behavior and Take Control UI. |
| `Sources/Graftty/Terminal/HostManagedZmxBackend.swift` | Mac native owner/follower resize/input gate. |
| `Sources/GrafttyMobileKit/Session/SessionClient.swift` | iOS owner/follower/preview semantics and `hello`/`takeControl`/`ownerResize`. |
| `Sources/GrafttyMobileKit/App/RootView.swift` | iOS terminal viewport sizing and bottom chrome measurement. |
| `Sources/GrafttyMobileKit/App/TerminalChromeViewport.swift` | Pure height-reservation helper and font-fit task key. |
| `Tests/**` and `web-client/src/**/*.test.tsx` | Automated verification surface. |
| `SPECS.md` | Generated requirements index; regenerate from `@spec` markers. |

## Task 1: Plan and Commit Coverage Audit

**Files:**
- Read: `docs/superpowers/plans/2026-06-21-explicit-display-ownership.md`
- Read: `docs/superpowers/specs/2026-06-21-explicit-display-ownership-design.md`
- Read: `git log --oneline --decorate`
- Modify: none unless a real missing artifact is found.

- [ ] **Step 1: Map tasks to commits**

Run:
```bash
git log --oneline --decorate -20
```
Expected: commits exist for protocol/store, web bridge/client, process-wide assembly, Mac gate, mobile ownership, chrome height reservation, preview/spec cleanup, and verification fixes.

- [ ] **Step 2: Check plan/task coverage**

Run:
```bash
rg -n "Task [1-9]|ownerResize|takeControl|TerminalChromeViewport|authoritative grid" docs/superpowers/plans/2026-06-21-explicit-display-ownership.md docs/superpowers/specs/2026-06-21-explicit-display-ownership-design.md
```
Expected: all major branch concepts are represented in the plan/spec.

- [ ] **Step 3: Report gaps**

If a planned task has no corresponding commit or test, stop and report it before implementation. Otherwise mark the audit complete.

## Task 2: Spec and Terminology Consistency Audit

**Files:**
- Inspect: `Sources/**`, `Tests/**`, `web-client/src/**`, `SPECS.md`
- Modify if needed: source `@spec` markers and generated `SPECS.md`

- [ ] **Step 1: Search for stale implicit ownership language**

Run:
```bash
rg -n "isSizeLeader|claimLeadershipIfNeeded|size[- ]leader|size leadership|size-leadership|serverGrid|not-leader|LeadershipPinch|onLeadershipClaim|leadership|only Phase 2 envelope" Sources Tests web-client/src SPECS.md
```
Expected: no current source/spec hits. Historical docs outside current source/specs may remain but must not drive generated requirements.

- [ ] **Step 2: Check protocol spec language**

Run:
```bash
rg -n "WEB-3\\.5|WEB-5\\.3|WEB-5\\.6|IOS-4\\.4|IOS-4\\.6|IOS-4\\.18|IOS-5\\.6|IOS-6\\.10|IPAD-2\\.5" Tests SPECS.md web-client/src
```
Expected: generated and source specs describe `hello`, `takeControl`, `ownerResize`, explicit display owner, preview role, and authoritative grid. Legacy resize is described only as compatibility.

- [ ] **Step 3: Regenerate specs if any source marker changes**

Run:
```bash
./scripts/generate-specs.py
./scripts/generate-specs.py --check
```
Expected: `--check` passes.

- [ ] **Step 4: Commit any spec cleanup**

Run:
```bash
git status --short
git add SPECS.md
git add Tests/GrafttyTests/Specs/WebTodo.swift Tests/GrafttyTests/Specs/IosTodo.swift Tests/GrafttyTests/Specs/IpadTodo.swift web-client/src/components/TerminalPane.test.tsx Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift Tests/GrafttyMobileKitTests/Terminal/TerminalWidthLayoutTests.swift Tests/GrafttyMobileKitTests/UI/PanePreviewFontApplicationTests.swift Tests/GrafttyMobileKitTests/UI/PanePreviewFontSizingTests.swift
git commit -m "Clean up vertical sizing merge specs"
```
Expected: commit only if Task 2 changed files. If `git status --short` shows a changed spec source not listed in the `git add` command, add that exact file too; do not add unrelated files.

## Task 3: Automated Verification Sweep

**Files:**
- Modify: none unless tests expose a defect.

- [ ] **Step 1: Run native ownership and bridge tests**

Run:
```bash
swift test --filter WebControlEnvelopeTests
swift test --filter SharedProtocolSurfaceTests
swift test --filter SessionDisplayOwnershipStoreTests
swift test --filter DisplayOwnershipAssemblyTests
swift test --filter WebSocketBridgeOwnershipTests
swift test --filter WebServerIntegrationTests
swift test --filter HostManagedZmxBackendTests
swift test --filter SurfaceHandleHostManagedTests
swift test --filter RightClickMenuTests
swift test --filter TerminalManager
```
Expected: all selected tests pass.

- [ ] **Step 2: Run mobile sizing and ownership tests**

Run:
```bash
swift test --filter PanePreview
swift test --filter TerminalChromeViewportTests
swift test --filter KeyboardFrameInsetTests
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrafttyMobileKitTests/SessionClientTests -only-testing:GrafttyMobileKitTests/TerminalPaneViewTests -only-testing:GrafttyMobileKitTests/TerminalWidthLayoutTests -only-testing:GrafttyMobileKitTests/PanePreviewFontSizingTests -only-testing:GrafttyMobileKitTests/PanePreviewFontApplicationTests -only-testing:GrafttyMobileKitTests/TerminalChromeViewportTests test
```
Expected: Swift package helper tests pass; iOS simulator selected suites pass. If `iPhone 17` is unavailable locally, substitute an installed iPhone simulator while preserving the same selected suites.

- [ ] **Step 3: Run web tests and regenerate bundled resources**

Run:
```bash
(cd web-client && pnpm test && pnpm build)
./scripts/build-web.sh
```
Expected: Vitest and Vite build pass; bundled resources are generated by script.

- [ ] **Step 4: Run generated/spec hygiene**

Run:
```bash
./scripts/generate-specs.py --check
git diff --check
git status --short --branch
```
Expected: generated specs are current, no whitespace errors, and the worktree is clean unless a deliberate fix commit was made.

## Task 4: Manual Validation Matrix and Handoff

**Files:**
- Modify: none by default.
- Optional modify: this plan, if manual results need to be recorded before merge.

- [ ] **Step 1: Preserve manual validation matrix**

Execute this matrix before calling the branch merge-ready. If the local environment cannot run the Mac+iOS live app flow, mark the branch **not manually validated** in the handoff and do not claim merge readiness beyond automated verification.

1. Mac owns, iOS follows: iOS width-fits Mac authoritative grid and cannot type.
2. iOS taps Take Control: PTY immediately resizes to iOS terminal content area; Mac becomes follower.
3. Keyboard opens while iOS owns: bottom shell row remains visible above the terminal control bar.
4. Hide keyboard then show compact affordance: terminal viewport reserves the compact row height, then immediately expands when chrome disappears.
5. Mac takes control back: iOS becomes follower and stops sending input/resize.
6. Owner disconnects: existing follower remains read-only; no silent auto-promotion occurs.

- [ ] **Step 2: Final review**

Dispatch one final code/spec reviewer against `HEAD`. Required result: no blocking findings.

- [ ] **Step 3: Handoff summary**

Report:
- final commit hash;
- verification commands that passed;
- clean/dirty worktree status;
- manual validation status for each matrix item, or an explicit statement that automated checks passed but live app validation is still pending.
