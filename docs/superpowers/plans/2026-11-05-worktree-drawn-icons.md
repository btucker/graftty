# Drawn Worktree Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents attach a small illustrated SVG to their Attention recap. Graftty validates it, colors it, renders it to PNG on the Mac, and shows it in place of the worktree emoji on Mac and mobile.

**Architecture:**
- **Storage:** the drawing is stored on `WorktreeEntry` as sanitized SVG plus an app-assigned OKLCH hue.
- **Clients:** they learn only a revision string through `SidebarWorktreeMetadata`. They fetch the rendered PNG with a new revision-checked management request, the same way project icons are fetched today.
- **Fallback:** the emoji stays everywhere a drawing is unavailable, including notifications, Linux hosts, older clients and remote Macs.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSImage` SVG decoding (verified on macOS 27: `_NSSVGImageRep` renders gradients and text), `XMLParser` (`FoundationXML` on Linux), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-05-worktree-drawn-icons-design.md`

## Global Constraints

- **Public repository:** no private project names, paths or images in fixtures, tests or docs. Use invented worktrees such as `parser-cache`.
- **Specs and tests:** every behavior gets an EARS `@spec` in a Swift Testing title, written RED first. Regenerate `SPECS.md` with `scripts/generate-specs.py`. No literal `\"` in `@spec` titles.
- **Builds:** run SwiftPM through `scripts/swiftpm`, never `--skip-build`.
- **Linux:** `GrafttyKit` must compile there. AppKit rendering stays behind `#if canImport(AppKit)`, and `XMLParser` comes from `#if canImport(FoundationXML)`.
- **Compatibility:**
  - Recaps without `icon` stay valid.
  - Persisted `WorktreeEntry` without the new keys decodes. New keys use `decodeIfPresent`.
  - Do not add `WorktreeEmojiSource` cases, because older builds would fail to decode them.
- **Mobile:** mobile code is verified on the iOS simulator. macOS `swift test` skips UIKit-guarded code.
- **Size limits:** SVG at most 16,384 UTF-8 bytes. Rendered PNG at 256 × 256 pixels, at most 262,144 bytes.

## Review Focus

1. **A drawing replaced without `purposeChanged`** must keep the old drawing (Task 3 test `keepsDrawingWithoutPurposeChange`).
2. **Malicious SVG** with `<script>`, `on*` attributes, `href="http://…"`, `<image>`, `<foreignObject>` or `style="…url(http…)"` must be rejected (Task 1 tests).
3. **A home checkout** with a drawing still shows the project icon (Task 4 test `homeCheckoutIgnoresDrawing`).
4. **A worktree with a drawing whose PNG has not loaded** shows its emoji, not a blank (Task 6 test `drawingFallsBackToEmoji`).
5. **A user-chosen emoji made after this ships** beats a later drawing, while legacy-migrated `.manual` emojis do not (Task 3 test `userChosenEmojiBeatsDrawing`).

## Spec IDs

| ID | Behavior |
|---|---|
| AGENT-3.33 | Validation |
| AGENT-3.34 | Adoption and redraw rule |
| AGENT-3.35 | Recap stripping |
| AGENT-3.36 | Guidance |
| LAYOUT-2.199 | Color assignment |
| LAYOUT-2.200 | Identity resolution |
| LAYOUT-2.201 | Rendering |
| LAYOUT-2.202 | Mac surfaces |
| LAYOUT-2.203 | Header wash |
| IOS-4.65 | Mobile surfaces |

---

### Task 1: SVG validation and color tokens

**Files:**
- Create: `Sources/GrafttyKit/Model/WorktreeDrawingSVG.swift`
- Test: `Tests/GrafttyKitTests/Model/WorktreeDrawingSVGTests.swift`

**Interfaces:**
- Produces: `public enum WorktreeDrawingSVG`
  - `static let maxBytes = 16_384`
  - `static func validate(_ svg: String) throws -> String`, which returns the trimmed SVG or throws `WorktreeDrawingSVG.Rejection`
  - `public enum Rejection: Error, Equatable, CustomStringConvertible`, with cases `tooLarge`, `malformed`, `element(String)`, `attribute(String)`, `paint(String)`, `reference(String)`
  - `static let tokens = ["primary", "primary-light", "primary-dark", "accent", "accent-light", "ink", "white", "none"]`

**Rules the validator enforces:**
- **Root:** an `<svg>` element with `viewBox="0 0 64 64"`.
- **Elements:** only `svg`, `g`, `defs`, `path`, `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `text`, `tspan`, `linearGradient`, `radialGradient`, `stop` and `title`.
- **Attributes:** only geometry, `transform`, `opacity`, `fill-opacity`, `stroke-*`, `fill`, `stroke`, `stop-color`, `offset`, `id`, gradient coordinates, `font-*`, `text-anchor`, `xmlns` and `viewBox`. That means no `style`, no `on*`, no `href` and no `class`.
- **Paint:** `fill`, `stroke` and `stop-color` values must be one of `tokens` or `url(#<id>)`, where the `id` is defined in the same document.

- [ ] **Step 1: Write failing tests**
  - `@spec AGENT-3.33: When an agent submits a worktree drawing, the application shall accept only a 64-unit SVG of at most 16384 bytes built from allowlisted shapes, gradients and text whose paints are palette tokens or local gradient references, and reject scripts, event handlers, external references, embedded images and foreign content.`
  - Cases:
    - `acceptsTokenDrawing`: a sample with a `path`, a `linearGradient` and a `text` round-trips.
    - `rejectsScript`
    - `rejectsEventAttribute` (`onload`)
    - `rejectsExternalHref` (`<use href="http://x">`)
    - `rejectsImage`
    - `rejectsForeignObject`
    - `rejectsStyleAttribute`
    - `rejectsRawColor` (`fill="#ff0000"` gives `.paint("#ff0000")`)
    - `rejectsUndefinedGradient` (`url(#missing)`)
    - `rejectsOversize` (16,385 bytes gives `.tooLarge`)
    - `rejectsWrongViewBox`
- [ ] **Step 2:** Run `scripts/swiftpm test --filter WorktreeDrawingSVGTests`. Expected: build failure (type missing).
- [ ] **Step 3:** Implement `validate` as a single `XMLParser` pass with a delegate that records the first rejection and the collected ids, then checks `url(#…)` references after parsing.
- [ ] **Step 4:** Run the tests again. Expected: all pass.
- [ ] **Step 5:** Commit: `Validate agent worktree drawings`.

### Task 2: Color assignment

**Files:**
- Create: `Sources/GrafttyKit/Model/WorktreeColorAssignment.swift`
- Test: `Tests/GrafttyKitTests/Model/WorktreeColorAssignmentTests.swift`

**Interfaces:**
- Produces: `public enum WorktreeColorAssignment`
  - `static func hue(avoiding taken: [Double]) -> Double`, which returns an OKLCH hue in `[0, 360)`
  - `static func hueDistance(_ a: Double, _ b: Double) -> Double`

**Algorithm:**
- **Candidates:** every 5° from 0 to 355.
- **Choice:** pick the candidate whose minimum circular distance to `taken` is largest. Break ties by the lowest hue.
- **Empty `taken`:** returns 25°, a warm default, so a first worktree does not default to the blue most project icons use.

- [ ] **Step 1: Write failing tests**
  - `@spec LAYOUT-2.199: When a linked worktree first receives a drawing, the application shall assign it a permanent OKLCH hue farthest from the hues of the other drawn worktrees in its project and from the project icon's dominant hue.`
  - Cases:
    - `firstHueIsWarmDefault`: `[]` gives `25`.
    - `oppositeOfSingle`: `[250]` gives `70`.
    - `fillsLargestGap`: `[0, 120, 240]` gives `60`.
    - `distanceWraps`: `hueDistance(350, 10) == 20`.
- [ ] **Step 2:** Run with `--filter WorktreeColorAssignmentTests`. Expected: build failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests again. Expected: pass.
- [ ] **Step 5:** Commit: `Assign distinct worktree drawing colors`.

### Task 3: Store, adopt and strip drawings

**Files:**
- Modify:
  - `Sources/GrafttyProtocol/SidebarNavigation.swift`: add `AttentionRecap.icon: String?`. It is excluded from `isValid` beyond `icon.utf8.count <= 16_384`.
  - `Sources/GrafttyKit/Model/WorktreeEntry.swift`: add three fields, plus coding keys and `decodeIfPresent`:
    - `drawing: WorktreeDrawing?`
    - `drawingHue: Double?`
    - `emojiChosenByUser: Bool`, default `false`
  - `Sources/GrafttyKit/Model/SidebarHostNavigation.swift`:
    - `adoptReportedDrawing`
    - `setManualEmoji` sets `emojiChosenByUser = true`, and the clear path resets it.
  - `Sources/GrafttyKit/Notification/AppState+ControlAttention.swift`: call adoption beside `adoptReportedEmoji` in `recordAgentRecap` and `recordStoppedTurn`, then set `recap.icon = nil` before the recap is stored or broadcast.
  - `Sources/GrafttyCLI/Attention.swift`: validate `icon` with `WorktreeDrawingSVG.validate`, report the rejection's description, and mention `icon` in the help text.
- Test:
  - `Tests/GrafttyKitTests/Model/WorktreeDrawingAdoptionTests.swift`
  - `Tests/GrafttyKitTests/CLI/AttentionReportIconTests.swift`

**Interfaces:**
- Consumes: `WorktreeDrawingSVG.validate` (Task 1) and `WorktreeColorAssignment.hue(avoiding:)` (Task 2).
- Produces:
  - `public struct WorktreeDrawing: Codable, Sendable, Equatable`, with fields `svg: String` and `revision: String`. `revision` is the SHA-256 hex of `svg` plus `":"` plus the hue rounded to an integer.
  - `public static func adoptReportedDrawing(_ recap: AttentionRecap?, worktreePath: String, projectHue: Double?, in repos: inout [RepoEntry])`

**Adoption rules:**
- **Ignore when:**
  - the recap is invalid;
  - `icon` is nil or fails validation;
  - the worktree is the home checkout;
  - a drawing exists and `purposeChanged != true`.
- **First drawing:** assign `drawingHue` using sibling `drawingHue`s plus `projectHue`. Never reassign the hue on a redraw.

- [ ] **Step 1: Write failing tests**
  - `@spec AGENT-3.34: When a valid recap carries a drawing for a linked worktree, the application shall adopt it if the worktree has none, replace it only when the same recap sets purposeChanged, keep its assigned hue across redraws, and ignore drawings for the home checkout.`
    - Cases:
      - `adoptsFirstDrawing`
      - `keepsDrawingWithoutPurposeChange`
      - `replacesOnPurposeChange` (the hue is unchanged)
      - `homeCheckoutIgnoresDrawing`
      - `siblingsGetDistinctHues`
  - `@spec AGENT-3.35: When the application records a recap that carried a drawing, it shall store and broadcast that recap without the drawing.`
    - Case: `stoppedTurnStripsIcon` checks that `lastAgentStop.recap?.icon == nil` after `recordStoppedTurn`.
  - `userChosenEmojiBeatsDrawing`, under LAYOUT-2.200 in Task 4: `setManualEmoji` then a drawing means the identity is still the emoji. It lives in Task 4's suite.
  - CLI: `rejectsScriptIconWithReason`. `AttentionReport.decodeRecap` throws a `ValidationError` whose text contains `script`.
  - Decoding: `decodesEntryWithoutDrawingKeys`. Legacy JSON decodes with `drawing == nil` and `emojiChosenByUser == false`.
- [ ] **Step 2:** Run with `--filter "WorktreeDrawingAdoptionTests|AttentionReportIconTests"`. Expected: failures.
- [ ] **Step 3:** Implement as listed.
- [ ] **Step 4:** Run the tests again. Expected: pass.
- [ ] **Step 5:** Commit: `Adopt agent drawings with a stable color`.

### Task 4: Identity resolution and the protocol

**Files:**
- Modify `Sources/GrafttyProtocol/SidebarNavigation.swift`:
  - `WorktreeIconIdentity` gains `case drawing(revision: String, emoji: String?)`.
  - `resolve(isMainCheckout:emoji:drawingRevision:emojiChosenByUser:)` resolves in this order:
    1. the home checkout uses `.project`;
    2. a user-chosen emoji uses `.emoji`;
    3. a drawing uses `.drawing`;
    4. an emoji uses `.emoji`;
    5. otherwise `.none`.
  - Keep the two-argument `resolve` as a convenience.
  - `SidebarWorktreeMetadata` gains `drawingRevision: String?` and `emojiChosenByUser: Bool?`.
  - `WorktreePanes.iconIdentity` uses the new fields.
- Modify `Sources/GrafttyProtocol/WorktreeManagementEnvelope.swift`:
  - Add `case worktreeIcon(worktreeID: String, revision: String)`, encoded as type `"worktree_icon"`.
  - Add the `targetsRelayedResource` arm where `worktreeID` cases live.
- Modify `Sources/GrafttyKit/Model/SidebarHostNavigation.swift` (`metadata(for:)`) and `WorktreeEntry.iconIdentity(in:)` to supply the new fields.
- Modify `effectiveEmoji` so it still returns the emoji for `.drawing`, which keeps notifications unchanged.
- Test:
  - `Tests/GrafttyProtocolTests/WorktreeIconIdentityTests.swift`
  - an envelope round-trip in the existing envelope test file (find it with `grep -rln project_icon Tests`)

**Interfaces:**
- Produces: `WorktreeIconIdentity.drawing(revision:emoji:)`, `ManagementRequest.worktreeIcon(worktreeID:revision:)` and `SidebarWorktreeMetadata.drawingRevision`.

- [ ] **Step 1: Write failing tests**
  - `@spec LAYOUT-2.200: While a linked worktree has an adopted drawing, the application shall identify it by that drawing ahead of an agent emoji, while a home checkout keeps its project icon and an emoji the user chose keeps precedence.`
  - Cases:
    - `drawingBeatsAgentEmoji`
    - `homeCheckoutIgnoresDrawing`
    - `userChosenEmojiBeatsDrawing`
    - `effectiveEmojiSurvivesDrawing`
    - `worktreeIconEnvelopeRoundTrips`
- [ ] **Step 2:** Run with `--filter "WorktreeIconIdentityTests|worktreeIconEnvelope"`. Expected: failures.
- [ ] **Step 3:** Implement. Fix every exhaustive `switch` over `WorktreeIconIdentity` and `ManagementRequest` that the compiler flags. Unsupported hosts return `.error(code: "unsupported"…)`, as they do today.
- [ ] **Step 4:** Run the tests, then `scripts/swiftpm build`. Expected: pass and a clean build.
- [ ] **Step 5:** Commit: `Resolve worktree identity from drawings`.

### Task 5: Rendering on the Mac and serving PNGs

**Files:**
- Create: `Sources/GrafttyKit/Model/WorktreeDrawingRenderer.swift`. The rendering code goes behind `#if canImport(AppKit)`.
- Modify:
  - `Sources/Graftty/App/GrafttyApp+WebRTCHostChannels.swift`: answer `.worktreeIcon`.
  - `Sources/GrafttyKit/Host/HeadlessHostControl.swift`: answer `.worktreeIcon` on AppKit, and return `.icon(nil)` elsewhere.
  - `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift`: forward `.worktreeIcon` through `relayRouter`, as `.open` does for worktree IDs.
- Test: `Tests/GrafttyKitTests/Apple/Model/WorktreeDrawingRendererTests.swift`

**Interfaces:**
- Consumes: `WorktreeDrawing` and `drawingHue` (Task 3).
- Produces:
  - `public enum WorktreeDrawingRenderer`
    - `static func palette(hue: Double) -> [String: String]`, mapping each token to an sRGB hex
    - `static func png(svg: String, hue: Double, pixels: Int = 256) -> Data?`
  - `public final class WorktreeDrawingImageCache`, a `@MainActor` shared cache keyed by `revision`, with `func png(for drawing: WorktreeDrawing, hue: Double) -> Data?`

**Palette:** OKLCH converted to sRGB.

| Token | L | C | Hue |
|---|---|---|---|
| `primary` | 0.60 | 0.15 | h |
| `primary-light` | 0.88 | 0.06 | h |
| `primary-dark` | 0.42 | 0.12 | h |
| `accent` | 0.74 | 0.16 | h + 40 |
| `accent-light` | 0.90 | 0.08 | h + 40 |

- **Fixed tokens:** `ink` is `#24242c` and `white` is `#ffffff`.
- **Rendering:** substitute the tokens, decode with `NSImage(data:)`, and draw into a 256-pixel RGBA bitmap.
- **White edge:** first draw the image's alpha as a white silhouette at 8 offsets of radius `pixels / 36`, then draw the image on top.

- [ ] **Step 1: Write failing tests**
  - `@spec LAYOUT-2.201: When a host serves a worktree drawing, the application shall fill its palette tokens from the worktree's hue, render it to a 256-pixel PNG with a white outline, and answer only requests whose revision matches the current drawing.`
  - Cases:
    - `rendersOpaquePixelsForTokenDrawing`
    - `primaryTokenUsesHue`: two hues give different center pixels.
    - `whiteEdgeSurroundsShape`: a pixel just outside a filled rect is white and opaque.
    - `staleRevisionReturnsNil`: tested through a small pure lookup function `WorktreeDrawingRenderer.iconResponse(for repos: [RepoEntry], worktreeID: String, revision: String) -> Data?`, which the handlers call.
- [ ] **Step 2:** Run with `--filter WorktreeDrawingRendererTests`. Expected: build failure.
- [ ] **Step 3:** Implement the renderer and lookup, then wire the three handlers.
- [ ] **Step 4:** Run the tests again. Expected: pass.
- [ ] **Step 5:** Commit: `Render and serve worktree drawings`.

### Task 6: Show drawings on Mac surfaces and the header wash

**Files:**
- Modify:
  - `Sources/GrafttyCommandUI/WorktreeIdentityView.swift`: the `.drawing` case shows `imageData` decoded unclipped. Without image data it shows the fallback emoji.
  - `Sources/GrafttyCommandUI/WorktreeHeaderWash.swift`: add `Glyph.drawing(Data)` (not clipped), and build it from `.drawing` when `iconData` decodes. Otherwise fall back to `.emoji`.
  - `Sources/Graftty/Views/WorktreeRow.swift`: show the drawing for linked worktrees with one, using `WorktreeDrawingImageCache`.
  - `Sources/Graftty/Views/BreadcrumbBar.swift` and `Sources/Graftty/Views/MainWindow.swift`: pass the drawing PNG as `iconData` / `imageData` when the identity is `.drawing`.
- Test: `Tests/GrafttyCommandUITests/WorktreeDrawingIdentityTests.swift`

**Interfaces:**
- Consumes: `WorktreeIconIdentity.drawing` (Task 4) and `WorktreeDrawingImageCache` (Task 5).

- [ ] **Step 1: Write failing tests**
  - `@spec LAYOUT-2.203: When the selected linked worktree has a drawing whose image is available, the application shall draw the header wash from that image without clipping it, and otherwise from its emoji.`
    - Cases: `washUsesDrawingImage` and `drawingFallsBackToEmoji` (no data gives `.emoji`).
  - `@spec LAYOUT-2.202: While a linked worktree with a drawing appears in the Mac sidebar or breadcrumb, the application shall show its rendered drawing in place of the emoji.`
    - Case: `identityViewShowsDrawing`, rendered with `ImageRenderer`. A pixel scan finds the drawing's primary color. Reuse the pixel helper pattern from `MobileWorktreeOverviewTests`.
- [ ] **Step 2:** Run with `--filter WorktreeDrawingIdentityTests`. Expected: failures.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests, then `scripts/swiftpm build`. Expected: pass and a clean build.
- [ ] **Step 5:** Commit: `Show worktree drawings on the Mac`.

### Task 7: Show drawings on mobile

**Files:**
- Create: `Sources/GrafttyCommandUI/WorktreeDrawingCache.swift`. It is `@Observable @MainActor`, keyed by revision, with `load(revision:fetch:)` and `reset()`, mirroring `ProjectIconCache`. It verifies the payload with `PNGThumbnail` limits: at most 262,144 bytes, and it must decode.
- Modify:
  - `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`: add `\.worktreeDrawingCache`.
  - `Sources/GrafttyMobileKit/App/RootView.swift`: own the cache and reset it when the selected host changes, beside `projectIconCache.reset()`.
  - `Sources/GrafttyMobileKit/UI/WorktreeListContent.swift`: load drawings for listed worktrees with `drawingRevision` through `.worktreeIcon`, detached from the view task, as `loadProjectIcons` does.
  - `Sources/GrafttyMobileKit/UI/WorktreeBlock.swift`, `Sources/GrafttyMobileKit/UI/MobileWorktreeOverviewView.swift` (`MobileWorktreeIdentity.iconData`) and `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`: pass drawing data for `.drawing` identities.
- Test:
  - `Tests/GrafttyCommandUITests/WorktreeDrawingCacheTests.swift`
  - an `IOS-4.65` case in `Tests/GrafttyMobileKitTests/UI/MobileWorktreeOverviewTests.swift`, inside its `canImport(UIKit)` guard

**Interfaces:**
- Consumes: `.worktreeIcon` (Task 4) and `WorktreeIconIdentity.drawing` (Task 4).

- [ ] **Step 1: Write failing tests**
  - `@spec IOS-4.65: When a worktree drawing has loaded on mobile, the application shall show it in the worktree list, the worktree header and the header wash, discard it when the selected host changes, and show the emoji until it loads.`
  - Cases:
    - `cacheStoresVerifiedDrawing`
    - `cacheRejectsOversizedPayload`
    - `cacheResetDropsDrawings`
    - `mobileHeaderShowsDrawing` (pixel scan)
- [ ] **Step 2:** Run the cache tests with `--filter WorktreeDrawingCacheTests`. Run the mobile test on the simulator with `xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrafttyMobileKitTests/MobileWorktreeIdentityTests`. Expected: failures.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run both again. Confirm the specific test's own `passed` line, not just the suite total. Expected: pass.
- [ ] **Step 5:** Commit: `Show worktree drawings on mobile`.

### Task 8: Agent guidance

**Files:**
- Modify:
  - `Sources/GrafttyKit/AgentPlugins/claude/plugins/graftty/skills/graftty/SKILL.md`
  - `Sources/GrafttyKit/AgentPlugins/codex/plugins/graftty/skills/graftty/SKILL.md`
  - `Sources/GrafttyKit/Teams/TeamHookRenderer.swift`: `skillGuidance`, `recapGuidance` and the Stop correction reason.
- Test: the existing guidance tests (find them with `grep -rln skillGuidance Tests`), plus one new assertion.

**Guidance content:** a short "Worktree drawing" section with:
- when to send `icon`: once the purpose is understood, and again only with `purposeChanged: true` when the old picture no longer fits;
- the subject, never the activity, plus one odd detail;
- the 64-unit view box, about 2.5-unit `ink` outlines, and palette tokens only;
- meaning carried by the silhouette at 15 points;
- shapes that stay legible in any hue;
- at most one supporting element from the project's world, never the subject;
- a compact token-only example drawing of an invented `parser-cache` worktree.

The emoji remains required.

- [ ] **Step 1: Write the failing test**
  - `@spec AGENT-3.36: When the application renders agent recap guidance, it shall explain the optional worktree drawing, its palette tokens and the redraw rule while still requiring an emoji.`
  - Assert that `TeamHookRenderer.skillGuidance` contains `icon`, `purposeChanged` and `primary`, and that both SKILL.md files contain `"icon"`.
- [ ] **Step 2:** Run the guidance test filter. Expected: failure.
- [ ] **Step 3:** Write the guidance. Validate that the example SVG passes `WorktreeDrawingSVG.validate` by adding it to a test as `guidanceExampleIsValid`.
- [ ] **Step 4:** Run the tests again. Expected: pass.
- [ ] **Step 5:** Commit: `Teach agents to draw worktree icons`.

### Task 9: Finish

- [ ] **Step 1:** Run `uv run scripts/generate-specs.py`, then `uv run scripts/generate-specs.py --check`. Expected: no diff after the commit.
- [ ] **Step 2:** Run `scripts/swiftpm test`, the full suite. Expected: all pass. Investigate any failure; do not rerun blindly.
- [ ] **Step 3:** Run the full iOS simulator `GrafttyMobileKitTests`. Expected: `TEST SUCCEEDED`, with the IOS-4.65 test's passed line present.
- [ ] **Step 4:** Run `/code-review xhigh --fix`, apply the fixes, and rerun the affected tests.
- [ ] **Step 5:** Update the design document's decisions to match three deviations:
  - The drawing travels on the recap.
  - Redraws without `purposeChanged` are silently ignored, not rejected with an error.
  - The color is assigned at first drawing, not at worktree creation.
- [ ] **Step 6:** Commit, push the branch and open a PR. The body ends with the Claude Code attribution line. Then confirm CI, including iOS.
