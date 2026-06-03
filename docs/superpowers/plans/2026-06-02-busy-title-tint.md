# Busy-title tint + attention pill beside title — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop rendering claude's busy state as a red `working…` pill; instead tint the (already-animating) pane title green while busy, and render real attention pings ("Claude needs input") to the right of the title (truncating the title) instead of replacing it.

**Architecture:** Split the two signals in `AgentLivenessMerge` (`effectivePaneText` = ping only; new `isPaneBusy`). Carry busy to iPad/web via a new `PaneLayoutNode.isBusy` wire field. A single shared theme helper `paneTitle(…, isBusy:)` produces the green tint, consumed identically by the Mac (`WorktreeRow`) and iPad (`WorktreeListContent`) renderers. Both renderers move the title out of the pill `else`-branch so title + pill render together.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`@Test`), Swift Package Manager (`swift test`). Specs via `@spec` annotations + `scripts/generate-specs.py` (see CLAUDE.md).

**Design:** `docs/superpowers/specs/2026-06-02-busy-title-tint-design.md`

**Execution dependency order:** Task 1–3 (foundation: merge, wire model, theme) are independent of each other but must all land before Task 4–5 (renderers). Task 4 (Mac) and Task 5 (iPad) touch disjoint files and may run in parallel after foundation. Task 6 (specs) is last.

**Note on iPad tests (per project memory):** macOS `swift test` does not compile UIKit-guarded `GrafttyMobileKit` view code, so iPad *render* behavior is validated by iOS CI, not locally. The cross-platform `PaneLayoutNode` Codable tests (GrafttyProtocol) DO run locally and are the foundation's real local gate.

---

## Task 1: Split `AgentLivenessMerge` — ping vs. busy

**Files:**
- Modify: `Sources/GrafttyKit/AgentLiveness/AgentLivenessMerge.swift`
- Test: `Tests/GrafttyTests/AgentLivenessMergeTests.swift`

- [ ] **Step 1: Rewrite the tests (RED)**

Replace the whole body of `Tests/GrafttyTests/AgentLivenessMergeTests.swift` with:

```swift
import Testing
@testable import GrafttyKit

@Suite("AgentLivenessMerge — pane attention split: effectivePaneText surfaces only the live notify ping; isPaneBusy derives busy from liveness.")
struct AgentLivenessMergeTests {
    @Test("""
@spec AGENT-2.1: While a pane has a live notify attention ping, the application shall render that ping in preference to any derived busy/idle status.
""")
    func notifyPingIsSurfaced() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: "build failed",
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == "build failed")
    }

    @Test("""
@spec AGENT-2.2: While a pane has no live attention ping, the application shall surface a busy claude session by tinting the pane title with the running/active color (not a capsule), and render the title unchanged when idle.
""")
    func busyProducesNoCapsuleTextButIsBusy() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil,
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == nil)
        #expect(AgentLivenessMerge.isPaneBusy(
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy]) == true)
    }

    @Test func idleIsNotBusyAndHasNoText() {
        #expect(AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil,
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .idle]) == nil)
        #expect(AgentLivenessMerge.isPaneBusy(
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .idle]) == false)
    }

    @Test func unknownSessionIsNotBusy() {
        #expect(AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil, sessionName: nil, liveness: [:]) == nil)
        #expect(AgentLivenessMerge.isPaneBusy(sessionName: nil, liveness: [:]) == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AgentLivenessMergeTests`
Expected: compile failure — `isPaneBusy` does not exist yet.

- [ ] **Step 3: Implement the split**

Replace `Sources/GrafttyKit/AgentLiveness/AgentLivenessMerge.swift` with:

```swift
import Foundation

/// Splits a pane's two independent signals. `effectivePaneText` surfaces
/// only a live `notify` ping (rendered as the red attention capsule).
/// `isPaneBusy` derives "claude is running" from liveness (rendered as a
/// green title tint, not a capsule) — the title already animates, so a
/// busy pane needs no separate pill. The two are rendered in different
/// places (capsule beside the title vs. tint *of* the title), so they do
/// not need to arbitrate each other here.
public enum AgentLivenessMerge {
    /// AGENT-2.1: the live notify ping, or nil. Busy/idle no longer feed
    /// this — busy is surfaced via `isPaneBusy` and a title tint instead.
    public static func effectivePaneText(
        paneAttentionText: String?,
        sessionName: String?,
        liveness: [String: AgentLiveness]
    ) -> String? {
        paneAttentionText
    }

    /// AGENT-2.2: true when the pane's claude session is busy. Purely
    /// liveness-derived; the caller decides to suppress the busy tint when
    /// a ping is also present (a needs-input ping supersedes "working").
    public static func isPaneBusy(
        sessionName: String?,
        liveness: [String: AgentLiveness]
    ) -> Bool {
        guard let sessionName else { return false }
        return liveness[sessionName] == .busy
    }
}
```

Note: `effectivePaneText` keeps its `sessionName`/`liveness` params (now unused) so the two existing call sites need no signature change in this task. They are simplified in Tasks 4 and 5 when those call sites are touched anyway.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AgentLivenessMergeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/AgentLiveness/AgentLivenessMerge.swift Tests/GrafttyTests/AgentLivenessMergeTests.swift
git commit -m "feat(AGENT-2.2): split AgentLivenessMerge into effectivePaneText (ping) + isPaneBusy"
```

---

## Task 2: Add `isBusy` to the `PaneLayoutNode` wire model

**Files:**
- Modify: `Sources/GrafttyProtocol/WorktreePanes.swift`
- Test: `Tests/GrafttyProtocolTests/WorktreePanesTests.swift`
- Mechanical call-site sweep (compiler-guided): every `.leaf(sessionName:title:attentionText:)` call site (39 total) across `Sources/` and `Tests/`.

- [ ] **Step 1: Add the round-trip + legacy-default tests (RED)**

Add these two tests inside the `struct` in `Tests/GrafttyProtocolTests/WorktreePanesTests.swift`:

```swift
    @Test
    func busyLeafRoundTrips() throws {
        let leaf = PaneLayoutNode.leaf(
            sessionName: "s", title: "t", attentionText: nil, isBusy: true)
        let data = try JSONEncoder().encode(leaf)
        let decoded = try JSONDecoder().decode(PaneLayoutNode.self, from: data)
        #expect(decoded == leaf)
        if case let .leaf(_, _, _, isBusy) = decoded {
            #expect(isBusy == true)
        } else {
            Issue.record("expected leaf")
        }
    }

    @Test
    func legacyLeafWithoutIsBusyDecodesAsFalse() throws {
        let legacy = #"{"kind":"leaf","sessionName":"s","title":"t"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PaneLayoutNode.self, from: legacy)
        if case let .leaf(_, _, _, isBusy) = decoded {
            #expect(isBusy == false)
        } else {
            Issue.record("expected leaf")
        }
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WorktreePanesTests`
Expected: compile failure — `.leaf` has no `isBusy` argument.

- [ ] **Step 3: Add `isBusy` to the enum, struct, walk, and Codable**

In `Sources/GrafttyProtocol/WorktreePanes.swift`:

Change the case (line ~172):
```swift
    case leaf(sessionName: String, title: String, attentionText: String?, isBusy: Bool)
```

Add to `Leaf` (after `attentionText`):
```swift
        public let attentionText: String?
        /// True while this pane's claude session is busy (AGENT-2.2).
        /// Renderers tint the title green rather than showing a capsule.
        public let isBusy: Bool
```
…and add `isBusy` to `Leaf`'s memberwise init if one is declared explicitly (if `Leaf` has no explicit init, the implicit memberwise init picks it up — but `collectLeaves` constructs it, see below).

Update `collectLeaves` (the `.leaf` case):
```swift
        case let .leaf(sessionName, title, attentionText, isBusy):
            out.append(Leaf(sessionName: sessionName, title: title,
                            attentionText: attentionText, isBusy: isBusy))
```

Add `isBusy` to `CodingKeys`:
```swift
        case kind, sessionName, title, attentionText, isBusy, direction, ratio, left, right
```

Update `init(from:)` `.leaf` case:
```swift
        case .leaf:
            self = .leaf(
                sessionName: try c.decode(String.self, forKey: .sessionName),
                title: try c.decode(String.self, forKey: .title),
                attentionText: try c.decodeIfPresent(String.self, forKey: .attentionText),
                isBusy: try c.decodeIfPresent(Bool.self, forKey: .isBusy) ?? false
            )
```

Update `encode(to:)` `.leaf` case:
```swift
        case let .leaf(sessionName, title, attentionText, isBusy):
            try c.encode(Kind.leaf, forKey: .kind)
            try c.encode(sessionName, forKey: .sessionName)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(attentionText, forKey: .attentionText)
            if isBusy { try c.encode(true, forKey: .isBusy) }
```
(Encode `isBusy` only when true so idle leaves keep their current compact JSON and legacy decoders are unaffected.)

If `Leaf` declares an explicit `init`, add `isBusy: Bool` to it with the other stored properties. Update the doc comment near line 168 to mention the optional `isBusy` field in the leaf wire shape.

- [ ] **Step 4: Sweep all `.leaf(...)` call sites (compiler-guided)**

Run `swift build` and add `isBusy:` to every now-erroring `.leaf(...)` call. Default to `isBusy: false` everywhere except where a test specifically exercises busy. The 39 sites live in:
`Sources/GrafttyMobileKit/UI/MobileNavigationDecision.swift`, `Sources/GrafttyMobileKit/UI/PaneLayoutView.swift`, and the test files under `Tests/GrafttyTests/`, `Tests/GrafttyMobileKitTests/`, `Tests/GrafttyProtocolTests/`.

Transformation (identical at each site):
```swift
// before
.leaf(sessionName: "x", title: "y", attentionText: z)
// after
.leaf(sessionName: "x", title: "y", attentionText: z, isBusy: false)
```
`Sources/Graftty/GrafttyApp.swift`'s `paneLayoutNode(…)` leaf is updated in Task 4 (it gets a real value, not `false`), so leave it erroring until then OR temporarily pass `isBusy: false` and finish it in Task 4. Pass `isBusy: false` here to keep the build green between tasks.

- [ ] **Step 5: Run the protocol tests + build**

Run: `swift test --filter WorktreePanesTests` then `swift build`
Expected: WorktreePanesTests PASS; build succeeds.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add isBusy to PaneLayoutNode wire model (backward-compatible)"
```

---

## Task 3: Theme helper — green tint when busy

**Files:**
- Modify: `Sources/GrafttyProtocol/UI/GhosttyThemeCore.swift`
- Modify: `Sources/Graftty/Terminal/GhosttyBridge.swift` (the forwarding `paneTitle`)
- Test: `Tests/GrafttyProtocolTests/WorktreePanesTests.swift` (add a small theme test here — it's the GrafttyProtocol test target that can import the type)

- [ ] **Step 1: Write the failing test (RED)**

Add to `Tests/GrafttyProtocolTests/WorktreePanesTests.swift`:

```swift
    @Test("@spec AGENT-2.2: busy pane title is tinted differently from an idle pane title in the same brightness bucket.")
    func busyTitleColorDiffersFromIdle() {
        let theme = GhosttyThemeColors.fallback
        let idle = theme.paneTitle(isFocusedPane: true, isActiveWorktree: true, hasTitle: true, isBusy: false)
        let busy = theme.paneTitle(isFocusedPane: true, isActiveWorktree: true, hasTitle: true, isBusy: true)
        #expect(idle != busy)
    }
```
(If `Color` equality proves unreliable in CI, compare `String(describing: idle) != String(describing: busy)` instead.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter busyTitleColorDiffersFromIdle`
Expected: compile failure — `paneTitle` has no `isBusy` parameter.

- [ ] **Step 3: Add the `isBusy` parameter (defaulted to false)**

In `Sources/GrafttyProtocol/UI/GhosttyThemeCore.swift`, change `paneTitle` (around line 149) to:

```swift
    func paneTitle(
        isFocusedPane: Bool,
        isActiveWorktree: Bool,
        hasTitle: Bool,
        isBusy: Bool = false
    ) -> Color {
        // AGENT-2.2: a busy pane reuses the running-state green
        // (worktreeStateIcon's `.green`) as the title base so "actively
        // working" is scannable, while keeping the same brightness ladder
        // so focus hierarchy still reads. Idle keeps the foreground base.
        let base: Color = isBusy ? .green : foreground
        return base.opacity(Self.paneTitleOpacity(
            isFocusedPane: isFocusedPane,
            isActiveWorktree: isActiveWorktree,
            hasTitle: hasTitle
        ))
    }
```

In `Sources/Graftty/Terminal/GhosttyBridge.swift`, update the forwarding wrapper (around line 119) to add and forward the parameter:

```swift
    func paneTitle(isFocusedPane: Bool, isActiveWorktree: Bool, hasTitle: Bool, isBusy: Bool = false) -> Color {
        core.paneTitle(
            isFocusedPane: isFocusedPane,
            isActiveWorktree: isActiveWorktree,
            hasTitle: hasTitle,
            isBusy: isBusy
        )
    }
```

The default value means existing callers compile unchanged; Tasks 4 and 5 opt in.

- [ ] **Step 4: Run the test + build**

Run: `swift test --filter busyTitleColorDiffersFromIdle` then `swift build`
Expected: PASS; build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyProtocol/UI/GhosttyThemeCore.swift Sources/Graftty/Terminal/GhosttyBridge.swift Tests/GrafttyProtocolTests/WorktreePanesTests.swift
git commit -m "feat(AGENT-2.2): paneTitle(isBusy:) green tint helper"
```

---

## Task 4: Mac renderer — busy tint + pill beside title

**Files:**
- Modify: `Sources/Graftty/Views/WorktreeRow.swift` (the `PaneTitleRow` struct, lines ~33–106)
- Modify: `Sources/Graftty/Views/SidebarView.swift` (the `PaneTitleRow(...)` call, lines ~293–305)
- Modify: `Sources/Graftty/GrafttyApp.swift` (`paneLayoutNode(...)`, lines ~3573–3591)
- Test: `Tests/GrafttyTests/Views/PaneTitleRowPortsTests.swift`

- [ ] **Step 1: Write the failing tests (RED)**

Add to `Tests/GrafttyTests/Views/PaneTitleRowPortsTests.swift` (note the new `isBusy:` parameter on every `PaneTitleRow(...)` in this file must be added in Step 3 — these new tests already pass it):

```swift
    @MainActor
    @Test("@spec LAYOUT-2.30: When a pane has an active attention capsule, the application shall render the capsule to the right of the pane title (not in place of it), truncating the title — so the row stays a single line rather than stacking the pill under the title.")
    func attentionPillRendersBesideTitleOnOneLine() {
        let containerWidth: CGFloat = 220
        func height(attention: String?) -> CGFloat {
            let row = PaneTitleRow(
                title: "Refactoring the parser module thoroughly",
                isActiveWorktree: true, isFocusedPane: true, theme: .fallback,
                attentionText: attention, isBusy: false, portBindings: [])
            return NSHostingController(rootView: row)
                .sizeThatFits(in: CGSize(width: containerWidth, height: 1000)).height
        }
        // A pill beside a (truncated) title occupies one line — within ~4pt
        // of the no-pill single-line height. Stacking the pill under the
        // title would roughly double it.
        #expect(abs(height(attention: "Claude needs input") - height(attention: nil)) < 6)
    }

    @MainActor
    @Test("@spec LAYOUT-2.22: A PaneTitleRow with a long title AND an attention capsule stays bounded by the row width (title truncates; pill keeps intrinsic size).")
    func longTitlePlusPillStaysBounded() {
        let containerWidth: CGFloat = 220
        let row = PaneTitleRow(
            title: String(repeating: "really-long-pane-title-segment-", count: 6),
            isActiveWorktree: true, isFocusedPane: true, theme: .fallback,
            attentionText: "Claude needs input", isBusy: false, portBindings: [])
        let preferred = NSHostingController(rootView: row)
            .sizeThatFits(in: CGSize(width: containerWidth, height: 1000))
        #expect(preferred.width <= containerWidth + 0.5)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaneTitleRowPortsTests`
Expected: compile failure — `PaneTitleRow` has no `isBusy:` parameter.

- [ ] **Step 3: Update `PaneTitleRow` in `WorktreeRow.swift`**

Add the `isBusy` stored property (after `isFocusedPane`, before `theme`), update the `attentionText` doc comment, factor the styled title into a shared builder, and split the body so the pill renders *beside* a truncating title. Replace the struct's properties + `body` (and add the helper) with:

```swift
    let isActiveWorktree: Bool
    let isFocusedPane: Bool
    /// True while this pane's claude session is busy (AGENT-2.2). Tints the
    /// title green — but only when no attention capsule is present, since a
    /// needs-input ping (claude waiting) supersedes "working".
    let isBusy: Bool
    let theme: GhosttyTheme
    /// When non-nil, an attention capsule renders to the *right* of the
    /// pane title (LAYOUT-2.30); the title truncates to make room rather
    /// than being replaced. Driven by shell-integration / `graftty notify`
    /// pings (NOTIF-2.x). Cleared when the user clicks the worktree
    /// (STATE-2.4). Worktree-scoped pings render on the worktree row
    /// instead (STATE-2.3).
    let attentionText: String?
    let portBindings: [PortBinding]

    var shouldRenderPortChips: Bool {
        attentionText == nil && !portBindings.isEmpty
    }

    /// Busy tint applies only when no capsule is shown (ping supersedes).
    private var titleIsBusyTinted: Bool { isBusy && attentionText == nil }

    @ViewBuilder
    private var titleText: some View {
        Text(title.isEmpty ? "shell" : title)
            .font(.caption)
            .fontWeight(isFocusedPane ? .semibold : .regular)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundColor(theme.paneTitle(
                isFocusedPane: isFocusedPane,
                isActiveWorktree: isActiveWorktree,
                hasTitle: !title.isEmpty,
                isBusy: titleIsBusyTinted
            ))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("↳")
                .font(.caption)
                .fontWeight(isFocusedPane ? .bold : .regular)
                .foregroundColor(theme.paneArrow(
                    isFocusedPane: isFocusedPane,
                    isActiveWorktree: isActiveWorktree
                ))
            if let attentionText {
                // LAYOUT-2.30: title (yields/truncates) + pill (keeps
                // intrinsic width) on one line. A plain HStack — NOT
                // FlowLayout — so the title truncates instead of the pill
                // wrapping below it.
                titleText
                    .layoutPriority(0)
                AttentionCapsule(text: attentionText)
                    .layoutPriority(1)
            } else {
                // Title + port chips share a FlowLayout so wrapped chips
                // hang under the title text (PORTS-3.3).
                FlowLayout(spacing: 4, rowSpacing: 3) {
                    titleText
                    if shouldRenderPortChips {
                        ForEach(portBindings, id: \.self) { binding in
                            PortChip(binding: binding, theme: theme)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
```

- [ ] **Step 4: Pass `isBusy` from `SidebarView`**

In `Sources/Graftty/Views/SidebarView.swift`, update the `PaneTitleRow(...)` call (around line 293) to compute and pass `isBusy`, and simplify `effectivePaneText` to its now-ping-only role:

```swift
                        PaneTitleRow(
                            title: terminalManager.displayTitle(for: terminalID),
                            isActiveWorktree: isActive,
                            isFocusedPane: isActive
                                && worktree.focusedPaneSlotID == terminalID,
                            isBusy: AgentLivenessMerge.isPaneBusy(
                                sessionName: worktree.paneSessions[terminalID]
                                    .map(ZmxLauncher.sessionName(for:)),
                                liveness: claudeSessionRegistry.livenessBySession),
                            theme: theme,
                            attentionText: AgentLivenessMerge.effectivePaneText(
                                paneAttentionText: attention.paneCapsules[terminalID],
                                sessionName: worktree.paneSessions[terminalID]
                                    .map(ZmxLauncher.sessionName(for:)),
                                liveness: claudeSessionRegistry.livenessBySession),
                            portBindings: portBindings.bindings[terminalID] ?? []
                        )
```

- [ ] **Step 5: Populate `isBusy` in `GrafttyApp.paneLayoutNode`**

In `Sources/Graftty/GrafttyApp.swift`, update the `.leaf(...)` construction (around line 3584) to set the real busy value:

```swift
        return .leaf(
            sessionName: sessionName ?? "",
            title: titles[id] ?? "",
            attentionText: AgentLivenessMerge.effectivePaneText(
                paneAttentionText: paneAttention[id]?.text,
                sessionName: sessionName,
                liveness: liveness),
            isBusy: AgentLivenessMerge.isPaneBusy(
                sessionName: sessionName,
                liveness: liveness)
        )
```

- [ ] **Step 6: Run tests + build**

Run: `swift test --filter PaneTitleRowPortsTests` then `swift build`
Expected: all PaneTitleRowPortsTests PASS (including existing PORTS-3.1/3.4 and LAYOUT-2.22); build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/Views/WorktreeRow.swift Sources/Graftty/Views/SidebarView.swift Sources/Graftty/GrafttyApp.swift Tests/GrafttyTests/Views/PaneTitleRowPortsTests.swift
git commit -m "feat(LAYOUT-2.30): Mac sidebar busy-title tint + attention pill beside title"
```

---

## Task 5: iPad/web renderer — busy tint + pill beside title

**Files:**
- Modify: `Sources/GrafttyMobileKit/UI/WorktreeListContent.swift` (the private `PaneTitleRow`, lines ~522–569)

- [ ] **Step 1: Update the iPad `PaneTitleRow` body**

In `Sources/GrafttyMobileKit/UI/WorktreeListContent.swift`, replace the `body` of the private `PaneTitleRow` (lines ~542–568) so the title always renders and the pill sits to its right, with the busy tint suppressed when a pill is present:

```swift
    var body: some View {
        // Busy tint applies only when no capsule is shown — a needs-input
        // ping (claude waiting) supersedes "working" (AGENT-2.2).
        let tintBusy = leaf.isBusy && effectiveAttentionText == nil
        HStack(spacing: 4) {
            Text("↳")
                .font(.caption)
                .fontWeight(isFocusedPane ? .bold : .regular)
                .foregroundStyle(themedOrSecondary(theme?.paneArrow(
                    isFocusedPane: isFocusedPane,
                    isActiveWorktree: isActiveWorktree
                )))
            // LAYOUT-2.30: title (truncates) then pill (intrinsic width).
            Text(leaf.displayTitle)
                .font(.caption)
                .fontWeight(isFocusedPane ? .semibold : .regular)
                .foregroundStyle(themedOrSecondary(theme?.paneTitle(
                    isFocusedPane: isFocusedPane,
                    isActiveWorktree: isActiveWorktree,
                    hasTitle: !leaf.displayTitle.isEmpty,
                    isBusy: tintBusy
                )))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            if let attentionText = effectiveAttentionText {
                AttentionCapsule(text: attentionText)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
    }
```

Update the `PaneTitleRow` doc comment (lines ~518–521) to say the capsule renders to the right of the title (not in place of it), matching LAYOUT-2.30.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds. (Per project memory, macOS `swift test` won't exercise this UIKit view; iOS CI on the PR is the real check.)

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/UI/WorktreeListContent.swift
git commit -m "feat(LAYOUT-2.30): iPad sidebar busy-title tint + attention pill beside title"
```

---

## Task 6: Regenerate SPECS.md

**Files:**
- Modify: `SPECS.md` (generated — never hand-edited)

- [ ] **Step 1: Regenerate**

Run: `scripts/generate-specs.py`
Expected: `SPECS.md` updates AGENT-2.2's text and adds LAYOUT-2.30; exit 0.

- [ ] **Step 2: Verify it's consistent**

Run: `scripts/generate-specs.py --check`
Expected: exit 0 (no staleness, no duplicate-ID errors).

- [ ] **Step 3: Commit**

```bash
git add SPECS.md
git commit -m "docs: regenerate SPECS.md for AGENT-2.2 + LAYOUT-2.30"
```

---

## Final verification (after all tasks)

- [ ] Run the full suite: `swift test` — expect green (all existing + new tests).
- [ ] `swift build` — expect success.
- [ ] `scripts/generate-specs.py --check` — expect exit 0.
- [ ] Run `/simplify` (CLAUDE.md requires it before any PR) and apply surfaced cleanups.
- [ ] Run `/code-review` and address findings.

## Self-review notes (spec coverage)

- Design §1 (split merge) → Task 1. §2 (theme tint) → Task 3. §3 (wire field) → Task 2. §4 (busy plumbed to renderers) → Tasks 4 (Mac, SidebarView + GrafttyApp) & 5 (iPad). §5 (pill beside title) → Tasks 4 & 5 bodies. Tint×pill precedence table → `titleIsBusyTinted` (Task 4) / `tintBusy` (Task 5). Specs (AGENT-2.2 reword, LAYOUT-2.30 new, LAYOUT-2.22 extended test, doc comments) → Tasks 1/3/4/5 titles + Task 6 regen.
- `busyText` constant deletion → folded into Task 1's full-file rewrite (it no longer appears).
- PORTS-3.4 preserved: `shouldRenderPortChips` keeps `attentionText == nil` (Task 4).
