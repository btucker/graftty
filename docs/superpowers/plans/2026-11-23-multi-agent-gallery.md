# Multi-agent Stage and Gallery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace agent tabs with a stage (the terminal in use) and a gallery (one live tile per agent, each with its own scroll rail) on Mac, iPad and iPhone, and show a worktree's agents as a logo stack in the sidebar.

**Architecture:** `WorkspaceLayout` keeps its groups: a group is a stage pane, its `selected` session is on stage, and its other sessions are off stage. The layout gains a gallery order and three mutators (`stage`, `removePane`, `moveTile`). A shared tile view in `GrafttyCommandUI` takes its thumbnail and rail as slots, so Mac fills them from `SurfaceHandle` and mobile from preview-role `SessionClient`s. Each platform's workspace view drops its tab header and adds the gallery.

**Tech Stack:** Swift 6, SwiftUI, AppKit/UIKit, Swift Testing, SwiftPM through `scripts/swiftpm`, XcodeGen for the mobile project.

**Spec:** `docs/superpowers/specs/2026-11-23-multi-agent-gallery-design.md`

## Global Constraints

- A tile never resizes a terminal and never takes display ownership. Mac tiles read text from the existing surface; mobile tiles attach with `SessionClient.Role.preview`.
- The gallery does not narrow the terminal while a worktree has one agent: it starts collapsed and its opener floats over the stage.
- Tile status is the pinned-tile dot only (orange filled while asking, pulsing blue while working, none otherwise); finished agents are dimmed. No accent borders, no per-agent colours.
- Requests apply to Mac and GrafttyMobile. The web client is out of scope.
- Requirements are `@spec` annotations in tests. Never edit `SPECS.md` by hand; run `scripts/generate-specs.py`. No literal quotes in `@spec` titles.
- Build and test with `scripts/swiftpm`. Mobile code under `#if canImport(UIKit)` is not compiled by it: compile it with the simulator build in `Apps/GrafttyMobile/README.md`, and run `cd Apps/GrafttyMobile && xcodegen generate` after adding a mobile test file.
- New spec ids continue each prefix's numbering: `LAYOUT-2.246` onward and `IOS-13.21` onward (confirm the next free id with `grep -o "LAYOUT-2\.[0-9]*" SPECS.md | sort -t. -k2 -n | tail -1` before using one).

## Review Focus

1. A layout saved before this change has no gallery order. Expected: it decodes, and tiles appear in canvas order. (Task 1)
2. The agent on stage finishes or is closed. Expected: the stage shows another agent or the completed content, never an empty pane while agents remain. (Task 1)
3. A tile is clicked while its agent is already on stage in another pane. Expected: that pane takes focus; no terminal is mounted twice. (Tasks 1, 4)
4. Two agents ask at once. Expected: each tile shows its own orange dot; the stage shows the worktree's current question. (Tasks 2, 4)
5. More agents than the phone's live-preview budget. Expected: extra tiles show a caption and status without a live thumbnail, and the app does not open more preview connections than the budget. (Task 9)

## File Structure

| File | Responsibility |
|---|---|
| `Sources/GrafttyProtocol/WorkspaceLayout.swift` (modify) | Gallery order, `stage`, `removePane`, `moveTile`, `galleryVisible` |
| `Sources/GrafttyCommandUI/AgentTileStatus.swift` (create) | Per-agent dot state and caption text, pure |
| `Sources/GrafttyCommandUI/AgentGalleryTile.swift` (create) | Tile view, empty tile, status dot view |
| `Sources/GrafttyCommandUI/AgentLogoStack.swift` (create) | Sidebar logo stack with halos |
| `Sources/GrafttyCommandUI/TerminalTextThumbnail.swift` (create) | Draws rows of text as a miniature |
| `Sources/GrafttyCommandUI/ScrollbackMapOverlay.swift`, `ScrollbackMapPreviews.swift` (modify) | Compact tile rail: unclipped cards, jump callback |
| `Sources/Graftty/Views/WorkspaceGallery.swift` (create) | Mac gallery column: tiles, thumbnails, rails, drag, opener |
| `Sources/Graftty/Views/WorkspaceContentView.swift`, `RemoteWorkspaceContentView.swift` (modify) | Remove tab header; stage actions; gallery |
| `Sources/Graftty/Views/MainWindowDetailLayout.swift`, `MainWindow.swift` (modify) | Gallery and Context share one column |
| `Sources/GrafttyCommandUI/WorktreeContextPanel.swift` (modify) | Remove the completed-agents list |
| `Sources/GrafttyCommandUI/SidebarWorktreeRowLayout.swift`, Mac and mobile `WorktreeBlock.swift` (modify) | Slot under the identity for the stack |
| `Sources/GrafttyMobileKit/UI/MobileAgentGallery.swift` (create) | Phone gallery screen and iPad gallery column |
| `Sources/GrafttyMobileKit/UI/MultiPaneDetailView.swift`, `Terminal/SingleSessionView.swift` (modify) | Remove tab header and agent menu; add gallery entry and asks chip |
| Deleted | `AgentTabStrip.swift`, `AgentTabStripLayoutTests.swift`, `CompactAgentBar` menu, `sidebarAgentSlots`, `sidebarAgentLeaves` and their tests |

---

### Task 1: Layout model

**Files:** Modify `Sources/GrafttyProtocol/WorkspaceLayout.swift`; test `Tests/GrafttyProtocolTests/WorkspaceLayoutTests.swift`.

**Produces:**
```swift
public private(set) var galleryOrder: [Session]      // persisted; absent in old data
public var galleryVisible: Bool?                     // nil = automatic
public var gallerySessions: [Session]                // every group session, galleryOrder first, then canvas order
public func isOnStage(_ session: Session) -> Bool    // selected in a group that is in `root`
public var focusedGroupID: UUID?                     // group of focusedSession, else of lastAgent, else first
public mutating func stage(_ session: Session)
@discardableResult public mutating func removePane(_ id: UUID) -> Bool
@discardableResult public mutating func moveTile(_ session: Session, relativeTo target: Session, after: Bool) -> Bool
public func showsGallery(agentCount: Int) -> Bool    // galleryVisible ?? (agentCount >= 2)
```

- [ ] **Step 1: Failing tests** (Swift Testing, one `@Test` each, titles are the `@spec` text):
  - `LAYOUT-2.246`: staging an off-stage session moves it into the focused group and selects it; the group's previous session stays in `gallerySessions` and `isOnStage` is false for it.
  - `LAYOUT-2.247`: staging a session already on stage in another group only changes `focusedSession`; group membership is unchanged.
  - `LAYOUT-2.248`: `removePane` on one of two groups keeps both sessions in `gallerySessions`, leaves the surviving group's `selected` unchanged, and returns false when one group remains.
  - `LAYOUT-2.249`: `gallerySessions` keeps its order across `stage`, `split` and `removePane`; `moveTile` changes it without changing any group's `selected` (replaces LAYOUT-2.186, whose test is deleted).
  - Decoding JSON produced by the current encoder (no `galleryOrder`, no `galleryVisible`) succeeds and yields `gallerySessions == canvasSessions`.
  - After `remove(selected)` on a group with two sessions, the other becomes `selected` (pins Review Focus 2).
- [ ] **Step 2:** `scripts/swiftpm test --filter WorkspaceLayoutTests` fails to compile.
- [ ] **Step 3: Implement.** Add a custom `init(from:)` using `decodeIfPresent` for the two new keys. `addAgent` appends to `galleryOrder`; `remove` drops from it only when the session leaves the layout entirely (not when `move` re-adds it: have `move`, `split` and `moveToDrawer` preserve the entry). `removePane` appends the group's sessions to the group that precedes it in `root.groupIDs` (or follows it) without selecting them.
- [ ] **Step 4:** tests pass. **Step 5:** commit.

### Task 2: Tile status and tile view

**Files:** Create `AgentTileStatus.swift`, `AgentGalleryTile.swift`, `TerminalTextThumbnail.swift` in `Sources/GrafttyCommandUI`; make `PinnedTileFace.working(isDark:)` and `.attention` usable by them; test `Tests/GrafttyCommandUITests/AgentTileStatusTests.swift`.

**Produces:**
```swift
public enum AgentTileDot: Equatable { case asking, working }
public struct AgentTileStatus: Equatable {
    public let dot: AgentTileDot?; public let isFinished: Bool; public let isAsleep: Bool
    public let caption: String        // question, else result, else status label
    public init(needsInput: Bool, isBusy: Bool, isCompleted: Bool, isCached: Bool,
                question: String?, result: String?, statusLabel: String)
}
public struct AgentStatusDot: View { public init(dot: AgentTileDot?, size: CGFloat = 7) }
public struct AgentGalleryTile<Thumbnail: View, Rail: View>: View {
    public init(title: String, status: AgentTileStatus, isOnStage: Bool, foreground: Color, background: Color,
                @ViewBuilder thumbnail: () -> Thumbnail, @ViewBuilder rail: () -> Rail)
}
public struct AgentGalleryEmptyTile: View { public init(foreground: Color) }   // dashed, "New agent"
public struct TerminalTextThumbnail: View { public init(rows: [String], columns: Int, foreground: Color) }
```

- [ ] **Step 1: Failing tests** (`LAYOUT-2.250`, mirroring LAYOUT-2.225 per agent): asking → `.asking` even when busy; busy and not asking → `.working`; completed → no dot, `isFinished`; cached → no dot, `isAsleep`; caption order question > result > status label.
- [ ] **Step 2–4:** fail, implement, pass. The tile is `HStack(spacing: 0) { VStack { thumbnail; caption } ; rail.frame(width: 16) }`, dimmed to 0.55 opacity when finished or asleep, with a 2-point foreground outline when `isOnStage`. `AgentStatusDot` moves the pip drawing out of `PinnedTileFace` so both use one implementation. `TerminalTextThumbnail` draws in a `Canvas` with a monospaced font sized to `width / columns / 0.6`, bottom-aligned.
- [ ] **Step 5:** commit.

### Task 3: Compact tile rail

**Files:** Modify `ScrollbackMapOverlay.swift`, `ScrollbackMapPreviews.swift`; test `Tests/GrafttyCommandUITests/ScrollbackMapOverlayTests.swift`.

**Produces:**
```swift
// ScrollbackMapOverlayHost gains:
//   compact: Bool = false                 // 16-point rail, cards not clipped to the rail's height
//   onJump: ((Int) -> Void)? = nil        // called with the row instead of model.scroll(toRow:)
// ScrollbackMapModel visibility becomes counted: setVisible(true) twice needs setVisible(false) twice.
```

- [ ] **Step 1: Failing tests:** `CONTEXT-57.15`: with `compact`, the preview frame's height is the card stack's height, not the rail's (assert on the pure layout function that today takes `availableHeight`); activating a mark with `onJump` set calls it and does not scroll the model. A model shown by two hosts keeps rebuilding after one hides.
- [ ] **Step 2–5:** fail, implement, pass, commit. Read the preview layout before choosing where the height comes from; keep the non-compact path byte-identical.

### Task 4: Mac stage and gallery

**Files:** Create `Sources/Graftty/Views/WorkspaceGallery.swift`; modify `WorkspaceContentView.swift`, `MainWindowDetailLayout.swift`, `MainWindow.swift`, `PaneCommands.swift`, `WorktreeContextPanel.swift`, `WorkspacePresentation.swift`; delete `AgentTabStrip.swift` and `Tests/GrafttyTests/Views/AgentTabStripLayoutTests.swift`; tests `Tests/GrafttyTests/Views/WorkspaceContentViewTests.swift`, `MainWindowDetailLayoutTests.swift`.

**Consumes:** Tasks 1–3. **Produces:** `WorkspaceContentView.stageAgent(_ slot: PaneSlotID)` (replaces `selectTab`, same test seam), `WorkspaceGallery` view, `WorkspaceGalleryColumnKey` preference carrying the gallery as the inspector's top half.

- [ ] **Step 1: Failing tests:**
  - `LAYOUT-2.190` reworded for tiles: `stageAgent` gives the terminal keyboard focus, including when already on stage.
  - `LAYOUT-2.251`: with one agent the gallery is hidden and the terminal has the content's full width; adding a second agent shows it without changing `focusedSession` (AGENT-6.128 still holds).
  - `CONTEXT-55` reworded: with gallery and Context both open the terminal loses one column's width (assert widths 0 and 360 cases as today, plus gallery-only).
  - `LAYOUT-2.196` reworded: a question from an off-stage agent shows at the top of the focused stage pane, named for the asker.
  - Next/previous agent commands cycle `gallerySessions`, staging each.
- [ ] **Step 2:** run, fail.
- [ ] **Step 3: Implement.**
  - `WorkspaceContentView`: delete `groupHeader`, `tabMenu`'s group items and the tab drop target. `paneHeader` returns a 24-point row (title, "Remove from stage" button) only while `layout.groups.count > 1`; publish `WorkspaceTabRowHeightKey` as 24 or 0 accordingly. `paneBanner` shows on the focused group. Drop on a pane edge calls `split`; drop in the centre calls `stage`.
  - `WorkspaceGallery`: one `AgentGalleryTile` per `layout.gallerySessions` that is an agent, then the empty tile wrapping the existing `NewAgentMenu`. Thumbnail: `TerminalTextThumbnail` fed from `handle.scrollbackRows(limit:)` on a 1-second `TimelineView`, for on-stage and off-stage agents alike. Rail: `ScrollbackMapOverlayHost(model: handle.scrollbackMapModel, timeline:…, compact: true, onJump:)` where `onJump` stages the agent and then scrolls. Click stages; drag uses the existing `WorkspaceTabDrag` payload; tiles reorder with `moveTile`. Context menu: Split beside stage, Close (the existing close cases).
  - Opener: a `WorkspaceControlGlass` pill at the stage's top-trailing corner while the gallery is hidden, showing "+" with one agent, else the count of agents whose dot is `.asking`.
  - `MainWindowDetailLayout`: the right column is `VStack { gallery; inspector }`, 220 points wide for the gallery alone and 360 with Context.
  - `WorktreeContextPanel`: delete `completedAgents` and its "Open agent tab" path; keep "Read transcript" reachable from the stage's completed content.
  - `PaneCommands.navigatePaneInTreeOrder`: cycle agents through `gallerySessions` with `stage`.
  - `WorktreeEntry.showAgentTab` renamed `stageAgent`, using `stage`.
- [ ] **Step 4:** `scripts/swiftpm test --filter "WorkspaceContentViewTests|MainWindowDetailLayoutTests|WorkspaceTabDragInteractionTests|WorkspaceDrawerContinuityTests"` passes; `scripts/swiftpm build`.
- [ ] **Step 5:** run the app (`run` skill) with two agents; confirm no resize is logged for an off-stage agent when the gallery opens. **Step 6:** commit.

### Task 5: Remote Mac workspace

**Files:** Modify `RemoteWorkspaceContentView.swift`, `RemoteWorktreeViewerController.swift`; tests `Tests/GrafttyTests/Remote/RemoteWorktreeViewerControllerTests.swift`.

- [ ] Same changes as Task 4 with `WorkspaceLayout<String>`: delete `header(_:)`, mount `WorkspaceGallery` (generalise its inputs to a small `GalleryAgent` value: `id`, `title`, `provider`, `status`, `isOnStage`, `handle: SurfaceHandle?`), keep `publishVisibility()` listing only on-stage sessions. Tests: existing viewer tests updated from `moveTab` to `moveTile`; `stage` publishes the new visible set. Commit.

### Task 6: Sidebar logo stack

**Files:** Create `AgentLogoStack.swift`; modify `SidebarWorktreeRowLayout.swift`, `Sources/Graftty/Views/WorktreeBlock.swift`, `SidebarView.swift`, `RemoteMacsSection.swift`, `Sources/GrafttyMobileKit/UI/WorktreeBlock.swift`, `WorktreeListContent.swift`; delete `sidebarAgentSlots`, `sidebarAgentLeaves` and their tests; test `Tests/GrafttyCommandUITests/AgentLogoStackTests.swift`.

**Produces:**
```swift
public struct AgentLogo: Identifiable, Equatable { public let id: String; public let provider: String?; public let title: String; public let status: AgentTileStatus }
public enum AgentLogoStackModel {
    public static func visible(_ logos: [AgentLogo], limit: Int = 5) -> (shown: [AgentLogo], overflow: Int)
    public static func zOrder(_ logo: AgentLogo) -> Double     // asking 2, working 1, else 0
}
public struct AgentLogoStack: View { public init(logos: [AgentLogo], background: Color, onSelect: @escaping (String) -> Void) }
// SidebarWorktreeRowLayout gains a third builder: `belowIdentity`, centred under the 60-point slot.
```

- [ ] **Step 1: Failing tests** (`LAYOUT-2.252`): fewer than two logos → nothing shown; seven logos → five and overflow 2; asking above working above idle; finished logos dimmed (status `isFinished`).
- [ ] **Step 2–4:** implement. 18-point logos overlapping by 5; halo is a 2-point ring plus soft glow in the dot colours, pulsing for working unless Reduce Motion. On Mac, hovering expands the stack (overlay, may cover the text column) and `.help(title)` on each logo; clicking calls `onSelect`, wired to `MainWindow.selectPane` after `stageAgent`. On mobile, tap expands and tap on a logo calls `onSelectPane`. Selecting a worktree row stages the first asking agent, if any (Mac: in `MainWindow`'s selection path).
- [ ] **Step 5:** commit.

### Task 7: iPad gallery

**Files:** Create `Sources/GrafttyMobileKit/UI/MobileAgentGallery.swift`; modify `MultiPaneDetailView.swift`, `PaneLayoutView.swift` (expose the preview tile as `MobileTerminalPreview`); test `Tests/GrafttyMobileKitTests/UI/MultiPaneDetailViewTests.swift`.

- [ ] Delete `tabHeader`; add the same slim pane header rule as Mac; mount `MobileAgentGalleryColumn` on the right with tiles whose thumbnail is `MobileTerminalPreview(client:)` using clients from a `PanePreviewClientPool` (preview role). On-stage agents' tiles reuse the caption and dot without a second connection. Tests: `selectSession` replaced by `stage`; a single-agent worktree shows no gallery column. Regenerate the Xcode project; compile for the simulator. Commit.

### Task 8: Phone stage chip

**Files:** Modify `Terminal/SingleSessionView.swift`, `UI/CompactAgentBar.swift`; test `Tests/GrafttyMobileKitTests/UI/MobileAttentionPaneTests.swift`.

- [ ] `CompactAgentBar` becomes a plain button showing the agent name and location (IOS-13.17 unchanged) that opens the gallery. Under the header, a chip "`<name>` asks" appears for the first other agent with `needsInput` and calls `selectWorkspaceSession`. Tests (`IOS-13.21`): chip present only when another agent asks; tapping selects it. Commit.

### Task 9: Phone gallery

**Files:** Modify `MobileAgentGallery.swift`, `SingleSessionView.swift`; test `Tests/GrafttyMobileKitTests/UI/MobileAgentGalleryTests.swift`.

**Produces:**
```swift
public enum MobileGalleryDensity: Int, Codable { case two = 2, four = 4
    public func after(pinchScale: CGFloat) -> MobileGalleryDensity   // > 1.25 → .two, < 0.8 → .four, else self
    public func tileSize(in size: CGSize, spacing: CGFloat) -> CGSize }
public enum MobileGalleryPreviewBudget { public static func live(sessions: [String], visible: Range<Int>, limit: Int = 4) -> Set<String> }
```

- [ ] **Step 1: Failing tests:** `IOS-13.22` density changes only between two and four; `IOS-13.23` three agents at 4-up place the empty tile fourth; budget never returns more than `limit` sessions and prefers visible ones (Review Focus 5).
- [ ] **Step 2–4:** implement the full-screen gallery as a `.fullScreenCover` from `SingleSessionView`: top row with Close, Terminal, About this worktree; a vertical `ScrollView` of fixed-size tiles; `MagnifyGesture` switching density, saved in `UserDefaults` key `workspace.iphone.gallery.density`; tap calls `selectWorkspaceSession`; tiles `.allowsHitTesting(false)` on the thumbnail. Tile rails on the phone use the timeline's marks without terminal rows (marks spaced by order), scrubbing shows cards, and lifting on a card selects the agent.
- [ ] **Step 5:** regenerate the Xcode project, simulator build, commit.

### Task 10: Requirements and review

- [ ] Remove `@spec` LAYOUT-2.245, 2.178, 2.186; reword LAYOUT-2.188, 2.196, 2.197, CONTEXT-55, IPAD-1.16 in their tests. Run `scripts/generate-specs.py` and `scripts/check-linux-test-allowlist.py`.
- [ ] `scripts/swiftpm test` (full), simulator build and the mobile unit tests touched above.
- [ ] `/code-review xhigh --fix`, then open the PR and confirm CI.
