# Sidebar PR Number Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display `#<number>` next to each worktree's sidebar icon, colored green for open PRs and purple for merged PRs, clickable to open the PR URL in the browser.

**Architecture:** Introduce a narrow `PRBadge` value type derived from `PRInfo`, replacing the existing `hasPR: Bool` parameter on `WorktreeRow`. Centralize the green/purple palette in a `PRInfo.State.statusColor` extension, consolidating a local helper currently duplicated inside `PRButton`. No changes to polling, fetchers, or hosting layer.

**Tech Stack:** Swift 5.10 / SwiftPM, SwiftUI, swift-testing (`@Suite`/`@Test`), macOS 14.

**Spec:** `docs/superpowers/specs/2026-04-19-sidebar-pr-number-badge-design.md`

---

## File Structure

**Create:**
- `Sources/EspalierKit/Hosting/PRBadge.swift` — narrow value type (number, state, url) for sidebar rendering. Lives in `EspalierKit` rather than the app target because it has no SwiftUI dependency and needs a pure-Swift test.
- `Tests/EspalierKitTests/Hosting/PRBadgeTests.swift` — equality coverage.

**Modify:**
- `Sources/Espalier/Views/WorktreeRow.swift` — replace `hasPR: Bool` parameter with `prBadge: PRBadge?`; add badge rendering between icon and branch label.
- `Sources/Espalier/Views/SidebarView.swift:149` — derive `PRBadge?` from `prStatusStore.infos`.
- `Sources/Espalier/Views/PRButton.swift` — delete local `mergedText` helper; add `PRInfo.State.statusColor` extension; use it in the merged-text-color call site.
- `SPECS.md` — add `PR-3.2`, `PR-3.3`, `PR-3.4` requirements under the existing PR section.

---

## Task 1: Define `PRBadge` value type

**Files:**
- Create: `Sources/EspalierKit/Hosting/PRBadge.swift`
- Test: `Tests/EspalierKitTests/Hosting/PRBadgeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/EspalierKitTests/Hosting/PRBadgeTests.swift`:

```swift
import Foundation
import Testing
@testable import EspalierKit

@Suite("PRBadge")
struct PRBadgeTests {
    private let sampleURL = URL(string: "https://github.com/btucker/espalier/pull/42")!
    private let otherURL = URL(string: "https://github.com/btucker/espalier/pull/99")!

    @Test func equalWhenAllFieldsMatch() {
        let a = PRBadge(number: 42, state: .open, url: sampleURL)
        let b = PRBadge(number: 42, state: .open, url: sampleURL)
        #expect(a == b)
    }

    @Test func inequalWhenNumberDiffers() {
        let a = PRBadge(number: 42, state: .open, url: sampleURL)
        let b = PRBadge(number: 43, state: .open, url: sampleURL)
        #expect(a != b)
    }

    @Test func inequalWhenStateDiffers() {
        let a = PRBadge(number: 42, state: .open, url: sampleURL)
        let b = PRBadge(number: 42, state: .merged, url: sampleURL)
        #expect(a != b)
    }

    @Test func inequalWhenURLDiffers() {
        let a = PRBadge(number: 42, state: .open, url: sampleURL)
        let b = PRBadge(number: 42, state: .open, url: otherURL)
        #expect(a != b)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PRBadgeTests 2>&1 | tail -20`

Expected: Build error — `cannot find 'PRBadge' in scope`.

- [ ] **Step 3: Implement `PRBadge`**

Create `Sources/EspalierKit/Hosting/PRBadge.swift`:

```swift
import Foundation

/// Minimal PR snapshot consumed by the sidebar row. Narrower than
/// `PRInfo` on purpose — only the fields the sidebar badge renders —
/// so that unrelated `PRInfo` changes (checks, title, fetchedAt) do
/// not invalidate the row via SwiftUI's equality diffing.
public struct PRBadge: Equatable, Sendable {
    public let number: Int
    public let state: PRInfo.State
    public let url: URL

    public init(number: Int, state: PRInfo.State, url: URL) {
        self.number = number
        self.state = state
        self.url = url
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter PRBadgeTests 2>&1 | tail -20`

Expected: All four tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Hosting/PRBadge.swift Tests/EspalierKitTests/Hosting/PRBadgeTests.swift
git commit -m "feat(pr): add PRBadge value type for sidebar rendering"
```

---

## Task 2: Centralize `PRInfo.State.statusColor`

**Files:**
- Modify: `Sources/Espalier/Views/PRButton.swift`

There's no Espalier-app test target, so this task has no direct test. The palette is locked by virtue of being a `switch` over a fixed enum — Swift's exhaustiveness check catches any missing case when a future `.closed` is added.

- [ ] **Step 1: Add `statusColor` extension and remove duplicate**

Open `Sources/Espalier/Views/PRButton.swift`. Current file ends at line 101 with the `PulseIfPending` modifier. Make three edits:

**Edit A** — delete lines 62-64 (the `private var mergedText` computed property):

```swift
    private var mergedText: Color {
        Color(red: 0.82, green: 0.66, blue: 1.0)
    }
```

**Edit B** — update the call site at line 24:

```swift
                .foregroundColor(info.state == .merged ? mergedText : theme.foreground)
```

becomes:

```swift
                .foregroundColor(info.state == .merged ? info.state.statusColor : theme.foreground)
```

**Edit C** — add a new extension at the bottom of the file (after the `PulseIfPending` struct, so it sits at file scope):

```swift
extension PRInfo.State {
    /// Color representing this PR's state. Green for open, purple for
    /// merged. Shared between the sidebar badge (foreground color of
    /// `#<number>`) and the breadcrumb pill (foreground color when
    /// merged). A future `.closed` case maps to red here.
    var statusColor: Color {
        switch self {
        case .open:   return Color(red: 0.25, green: 0.73, blue: 0.31)
        case .merged: return Color(red: 0.82, green: 0.66, blue: 1.0)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -10`

Expected: Build succeeds (no warnings-as-errors).

- [ ] **Step 3: Commit**

```bash
git add Sources/Espalier/Views/PRButton.swift
git commit -m "refactor(pr): centralize PR state color in PRInfo.State.statusColor"
```

---

## Task 3: Update `WorktreeRow` to consume `PRBadge?`

**Files:**
- Modify: `Sources/Espalier/Views/WorktreeRow.swift`

- [ ] **Step 1: Replace `hasPR` parameter**

In `Sources/Espalier/Views/WorktreeRow.swift`, find the current declaration at lines 110-113:

```swift
    /// True when a PR/MR is associated with this worktree's branch.
    /// Drives the leading-icon swap to the pull-request glyph (PR-3.1).
    /// A `Bool` rather than `PRInfo?` so the row doesn't re-render when
    /// PR fields it doesn't display (checks, title) change on each poll.
    let hasPR: Bool
```

Replace with:

```swift
    /// Narrow PR snapshot for this worktree, or nil when no PR/MR is
    /// associated. Drives (a) the leading-icon swap to the pull-request
    /// glyph (PR-3.1) and (b) the colored `#<number>` badge rendered
    /// between icon and branch label (PR-3.2, PR-3.3). `PRBadge` is
    /// deliberately narrower than `PRInfo` so unrelated changes (CI
    /// checks, title, fetchedAt) don't invalidate the row on each poll.
    let prBadge: PRBadge?
```

- [ ] **Step 2: Update `body` layout**

Find the `body` at lines 115-130. Current:

```swift
    var body: some View {
        HStack(spacing: 6) {
            typeIcon
            branchLabel
            Spacer()
            WorktreeRowGutter(
                stats: entry.state == .stale ? nil : stats,
                baseRef: baseRef,
                theme: theme
            )
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
```

Replace with:

```swift
    var body: some View {
        HStack(spacing: 6) {
            typeIcon
            if let prBadge {
                prBadgeLabel(prBadge)
            }
            branchLabel
            Spacer()
            WorktreeRowGutter(
                stats: entry.state == .stale ? nil : stats,
                baseRef: baseRef,
                theme: theme
            )
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
```

- [ ] **Step 3: Update `typeIcon` to read from `prBadge`**

Find the `typeIcon` computed view at lines 137-146:

```swift
    @ViewBuilder
    private var typeIcon: some View {
        Image(systemName: WorktreeRowIcon.symbolName(
            isMainCheckout: isMainCheckout,
            hasPR: hasPR
        ))
            .font(.system(size: 10))
            .foregroundColor(typeIconColor)
            .frame(width: 12)
    }
```

Replace with:

```swift
    @ViewBuilder
    private var typeIcon: some View {
        Image(systemName: WorktreeRowIcon.symbolName(
            isMainCheckout: isMainCheckout,
            hasPR: prBadge != nil
        ))
            .font(.system(size: 10))
            .foregroundColor(typeIconColor)
            .frame(width: 12)
    }
```

- [ ] **Step 4: Add `prBadgeLabel` view builder**

Insert this method after the `typeIcon` / `typeIconColor` block (anywhere in the struct; putting it next to `branchLabel` is natural). Add `import AppKit` at the top of the file if it's not already imported (needed for `NSWorkspace`).

Check the existing imports at the top of the file:

Current (lines 1-2):

```swift
import SwiftUI
import EspalierKit
```

Change to:

```swift
import SwiftUI
import AppKit
import EspalierKit
```

Then add the view builder inside the `WorktreeRow` struct. The badge uses a nested `Button` (not `.onTapGesture`) because the entire row is already wrapped in a `Button` in `SidebarView.swift:135-151` — nested Buttons with `.buttonStyle(.plain)` are the standard SwiftUI pattern for inner interactive elements and correctly receive the click without triggering the outer button.

```swift
    @ViewBuilder
    private func prBadgeLabel(_ badge: PRBadge) -> some View {
        Button {
            NSWorkspace.shared.open(badge.url)
        } label: {
            Text("#\(badge.number)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(badge.state.statusColor)
        }
        .buttonStyle(.plain)
        .help("Open #\(badge.number) on \(badge.url.host ?? "")")
        .accessibilityLabel(badgeAccessibilityLabel(badge))
    }

    private func badgeAccessibilityLabel(_ badge: PRBadge) -> String {
        let stateWord = badge.state == .open ? "open" : "merged"
        return "Pull request \(badge.number), \(stateWord). Click to open in browser."
    }
```

- [ ] **Step 5: Build to verify the row compiles**

Run: `swift build 2>&1 | tail -20`

Expected: Build fails with errors about `SidebarView.swift` — it still passes `hasPR:` which no longer exists. That's the next task. Confirm the only errors are in `SidebarView.swift` (not elsewhere), which proves nothing else in the codebase references `hasPR` on `WorktreeRow`.

- [ ] **Step 6: Do NOT commit yet**

This task's changes don't compile standalone — they need Task 4 to land together. Move to Task 4.

---

## Task 4: Update `SidebarView` to pass `PRBadge?`

**Files:**
- Modify: `Sources/Espalier/Views/SidebarView.swift`

- [ ] **Step 1: Replace `hasPR` call site with `prBadge`**

Open `Sources/Espalier/Views/SidebarView.swift`. Find line 149:

```swift
                    hasPR: prStatusStore.infos[worktree.path] != nil
```

Replace with:

```swift
                    prBadge: prStatusStore.infos[worktree.path].map {
                        PRBadge(number: $0.number, state: $0.state, url: $0.url)
                    }
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -10`

Expected: Build succeeds.

- [ ] **Step 3: Run all tests**

Run: `swift test 2>&1 | tail -30`

Expected: All tests pass (no tests should have regressed; `PRBadgeTests` still passes; existing `WorktreeRowIconTests` unchanged).

- [ ] **Step 4: Commit Tasks 3 and 4 together**

```bash
git add Sources/Espalier/Views/WorktreeRow.swift Sources/Espalier/Views/SidebarView.swift
git commit -m "feat(pr): show PR number badge in sidebar (PR-3.2, PR-3.3, PR-3.4)"
```

---

## Task 5: Update SPECS.md

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Locate the existing PR section**

Run: `grep -n "^### PR\|^## .*PR\|^\*\*PR-3\." SPECS.md`

Identify the anchor for `PR-3.1` (the icon-swap requirement). The new requirements extend its numbering as `PR-3.2`, `PR-3.3`, `PR-3.4`.

- [ ] **Step 2: Insert the new requirements**

Immediately after the `PR-3.1` line in `SPECS.md`, add:

```markdown
**PR-3.2** While a worktree has an associated open PR/MR, the application shall render `#<number>` in green to the right of the worktree's icon in the sidebar row.

**PR-3.3** While a worktree has an associated merged PR/MR, the application shall render `#<number>` in purple to the right of the worktree's icon in the sidebar row.

**PR-3.4** When the user clicks the PR/MR number in a sidebar row, the application shall open the PR/MR URL in the default browser via `NSWorkspace.shared.open` and shall not change the currently-selected worktree.
```

Match the formatting style of surrounding requirements (blank line between each `**ID**` block, prose wording consistent with EARS templates in `CLAUDE.md`).

- [ ] **Step 3: Commit**

```bash
git add SPECS.md
git commit -m "docs(specs): PR-3.2/3.3/3.4 sidebar PR number badge"
```

---

## Task 6: Manual smoke test

**Files:** None — running the app.

- [ ] **Step 1: Build and launch**

Run: `swift build 2>&1 | tail -5 && swift run Espalier &`

(Or launch via Xcode if that's the established pattern.)

- [ ] **Step 2: Verify badge on an open PR**

Open Espalier on a repo where at least one worktree has an open PR. Confirm:

- `#<number>` appears in green immediately to the right of the worktree's icon.
- The icon is `arrow.triangle.pull` (the PR glyph, existing behavior — regression check).
- Clicking the number opens the PR in the default browser.
- Clicking the number does NOT change the selected worktree (the previous selection persists).

- [ ] **Step 3: Verify merged PR color**

Either find a worktree whose PR has already merged, or merge one and wait ~5 minutes for the poll cycle. Confirm:

- The badge color transitions from green to purple.
- The icon stays as `arrow.triangle.pull`.

- [ ] **Step 4: Verify no-PR worktrees are unchanged**

Confirm worktrees without a PR show no badge (no `#` text) and use the house/branch icon as before — the only visual change is for worktrees that have PRs.

- [ ] **Step 5: Stop the app**

Quit Espalier cleanly (Cmd-Q).

No commit for this task — it's verification.

---

## Self-Review Notes

**Spec coverage:**
- `PRBadge` type (spec §3.1) → Task 1 ✓
- `SidebarView` derivation (spec §3.2) → Task 4 ✓
- Row rendering layout (spec §4.1–4.3) → Task 3 ✓
- Tap-through handling (spec §4.4) → Task 3 (nested Button pattern) ✓
- `statusColor` extension (spec §5.1) → Task 2 ✓
- `PRButton.mergedText` consolidation (spec §5.2) → Task 2 ✓
- `PRBadge` equality test (spec §6.1) → Task 1 ✓
- `statusColor` palette test (spec §6.2) → Deferred: no Espalier-app test target exists; the switch exhaustiveness + manual smoke test (Task 6) covers this adequately. Adding a test target is out of scope for this change.
- Row rendering tests (spec §6.3) → Deferred: same reason. The `WorktreeRowIcon` icon-symbol logic (the only pure-Swift portion of row rendering) is already covered by existing `WorktreeRowIconTests`, and the icon-swap behavior is unchanged.
- Manual smoke (spec §6.4) → Task 6 ✓
- SPECS.md requirements (spec §7) → Task 5 ✓

**Type/name consistency:** `PRBadge` (public struct, `number`/`state`/`url` fields) used consistently across Tasks 1, 3, 4. `PRInfo.State.statusColor` (computed property) used consistently across Tasks 2 and 3. `prBadge:` label name used consistently across Tasks 3 and 4.

**Placeholder scan:** No "TBD", no "implement later", no under-specified steps. Every code block is complete and copy-pasteable.

**Scope check:** One coherent change, one spec, one PR. No decomposition needed.
