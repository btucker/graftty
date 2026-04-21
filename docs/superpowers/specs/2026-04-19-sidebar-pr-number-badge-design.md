# Sidebar PR Number Badge — Design Specification

Display the PR/MR number next to the icon in each worktree sidebar row, colored by state (green for open, purple for merged). Clicking the number opens the PR/MR in the default browser. This extends the existing PR/MR status display (which today only surfaces as the breadcrumb pill and the sidebar icon swap) with a per-row status indicator.

## 1. Goals and Non-Goals

**Goals:**

- For every worktree with an associated open PR/MR, the sidebar row shall display `#<number>` in green to the right of the worktree's icon.
- For merged PRs/MRs, the number shall render in purple.
- Clicking the number shall open the PR/MR URL in the default browser without changing the selected worktree.
- Row re-render behavior must be preserved: changes to CI checks, PR title, or `fetchedAt` must NOT invalidate the sidebar row (only number, state, or URL transitions may).
- The color palette shall live in a single source of truth, shared with the existing `PRButton`.

**Non-goals (explicit):**

- Closed-unmerged PR state (red). `PRInfo.State` still has no `.closed` case; fetchers continue to filter out closed-unmerged PRs. Deferred to a follow-up spec.
- Any change to the breadcrumb `PRButton` beyond consuming the shared color helper.
- Per-state hover / pressed styling on the sidebar badge.
- Context menu (refresh / copy URL) on the badge — the breadcrumb pill already has this for when the user needs those actions.
- Animation of the color transition when a PR moves from open to merged.

## 2. Architecture

This is a small extension of the existing PR status infrastructure. No new stores, no new pollers — the data already flows from `PRStatusStore.infos` to `SidebarView` to `WorktreeRow`. The change is:

1. A narrow value type (`PRBadge`) replaces `hasPR: Bool` on the row, carrying exactly the three fields the badge renders.
2. `WorktreeRow` adds one new `@ViewBuilder` that renders the badge label.
3. `PRInfo.State.statusColor` becomes the single source of truth for the green/purple palette, replacing the inline `mergedText` helper in `PRButton`.

No changes to `GrafttyKit`'s hosting layer, no changes to polling cadence, no changes to fetchers.

## 3. Data Flow

### 3.1 `PRBadge` value type

New file: `Sources/Graftty/Views/PRBadge.swift` (app-target; sidebar is app-level UI).

```swift
import Foundation
import GrafttyKit

/// Minimal PR snapshot consumed by the sidebar row. Narrower than
/// `PRInfo` on purpose — only the fields the sidebar badge renders —
/// so that unrelated `PRInfo` changes (checks, title, fetchedAt) do
/// not invalidate the row via SwiftUI's equality diffing.
struct PRBadge: Equatable {
    let number: Int
    let state: PRInfo.State
    let url: URL
}
```

Lives in the app target (not `GrafttyKit`) because it's a view-layer concern — `GrafttyKit` should remain UI-free. If a future consumer needs a similar narrow type outside the app target, it can be promoted then.

### 3.2 `SidebarView` derivation

In `SidebarView.swift` where the existing `hasPR` is computed (line 149), replace:

```swift
hasPR: prStatusStore.infos[worktree.path] != nil
```

with:

```swift
prBadge: prStatusStore.infos[worktree.path].map {
    PRBadge(number: $0.number, state: $0.state, url: $0.url)
}
```

No other sites read `hasPR` — the existing parameter is only used by `WorktreeRow`.

## 4. `WorktreeRow` Rendering

### 4.1 Parameter change

Replace:

```swift
let hasPR: Bool
```

with:

```swift
let prBadge: PRBadge?
```

The existing icon-swap call becomes:

```swift
Image(systemName: WorktreeRowIcon.symbolName(
    isMainCheckout: isMainCheckout,
    hasPR: prBadge != nil
))
```

`WorktreeRowIcon.symbolName` stays in `GrafttyKit` unchanged — it still takes a `Bool` and knows nothing about `PRBadge`.

### 4.2 Layout

The row's `HStack` gains one element between `typeIcon` and `branchLabel`:

```swift
HStack(spacing: 6) {
    typeIcon
    if let prBadge {
        prBadgeLabel(prBadge)
    }
    branchLabel
    Spacer()
    WorktreeRowGutter(...)
}
```

### 4.3 `prBadgeLabel`

```swift
@ViewBuilder
private func prBadgeLabel(_ badge: PRBadge) -> some View {
    Text("#\(badge.number)")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(badge.state.statusColor)
        .help("Open #\(badge.number) on \(badge.url.host ?? "")")
        .accessibilityLabel(accessibilityLabel(for: badge))
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(badge.url) }
}

private func accessibilityLabel(for badge: PRBadge) -> String {
    let stateWord = badge.state == .open ? "open" : "merged"
    return "Pull request \(badge.number), \(stateWord). Click to open in browser."
}
```

### 4.4 Tap-through concern

`SidebarView` uses SwiftUI's `List(selection:)` for worktree selection — selection is bound through the list's selection mechanism, not a manual `.onTapGesture` on the row. In that pattern, an inner `.onTapGesture` attached to a non-selection element typically fires *without* also triggering selection.

If implementation reveals that the row still selects when the badge is tapped (platform-dependent behavior), the escape hatch is to wrap the badge in a `Button` with `.buttonStyle(.plain)`:

```swift
Button {
    NSWorkspace.shared.open(badge.url)
} label: {
    Text("#\(badge.number)")
        .font(.caption)
        ...
}
.buttonStyle(.plain)
```

Verify the `onTapGesture` form works first; fall back to `Button` only if needed.

## 5. Color Palette (Centralized)

### 5.1 `PRInfo.State.statusColor`

New file or addition in `Sources/Graftty/Views/PRButton.swift` (keeps the color palette next to its primary consumer):

```swift
extension PRInfo.State {
    /// Color representing this PR's state. Used by the sidebar badge
    /// (foreground color of `#<number>`) and the breadcrumb pill
    /// (foreground color when merged). Green for open, purple for merged.
    /// A future `.closed` case would map to red here.
    var statusColor: Color {
        switch self {
        case .open:   return Color(red: 0.25, green: 0.73, blue: 0.31)
        case .merged: return Color(red: 0.82, green: 0.66, blue: 1.0)
        }
    }
}
```

### 5.2 `PRButton` consolidation

Delete `PRButton.mergedText` (lines 62-64) and replace the one call site:

```swift
.foregroundColor(info.state == .merged ? mergedText : theme.foreground)
```

with:

```swift
.foregroundColor(info.state == .merged ? info.state.statusColor : theme.foreground)
```

The merged *background* tint at `PRButton.swift:57-60` stays untouched — it's a 15%-alpha background derived from (but not identical to) the merged purple, and only the breadcrumb pill uses it. Extracting it would be speculative generality.

## 6. Testing

### 6.1 `PRBadge` equality

Pure unit test (app-target, new file `Tests/.../PRBadgeTests.swift`): verify `PRBadge` instances with different `number`, `state`, or `url` are unequal, and instances with the same fields are equal. Trivial but worth the coverage — its whole purpose is equality-based diffing.

### 6.2 `PRInfo.State.statusColor`

Pure unit test: assert `.open.statusColor` and `.merged.statusColor` return the expected `Color` values (compare against literal RGB components). This locks the palette so an accidental tweak to one call site doesn't silently change branding.

### 6.3 Row rendering

Extend `Tests/GrafttyKitTests/Model/WorktreeRowIconTests.swift` (or create a sibling `WorktreeRowBadgeTests.swift` in the Graftty target, since `PRBadge` lives there):

- `prBadge == nil` → icon is non-PR glyph; no `#` text in the row.
- `prBadge.state == .open` → icon is PR glyph; `#<number>` present with open color.
- `prBadge.state == .merged` → icon is PR glyph; `#<number>` present with merged color.

Use SwiftUI introspection / ViewInspector if already depended on; otherwise assert on the derived `WorktreeRowIcon.symbolName` and a view-tree traversal pattern consistent with existing row tests.

### 6.4 Manual smoke

On a real repo with `gh` installed, open Graftty with a worktree that has an open PR and verify:
- Badge renders green.
- Clicking the badge opens the browser without changing the sidebar selection.
- Merging the PR upstream → within one polling cycle, the badge turns purple.

## 7. EARS Requirements (SPECS.md additions)

Under the existing PR/MR Status Display section in `SPECS.md`, extending the existing `PR-3.*` numbering:

- **PR-3.2** While a worktree has an associated open PR/MR, the application shall render `#<number>` in green to the right of the worktree's icon in the sidebar row.
- **PR-3.3** While a worktree has an associated merged PR/MR, the application shall render `#<number>` in purple to the right of the worktree's icon in the sidebar row.
- **PR-3.4** When the user clicks the PR/MR number in a sidebar row, the application shall open the PR/MR URL in the default browser and shall not change the currently-selected worktree.

## 8. Migration

One-shot change within the single PR for this spec:

1. Add `PRBadge.swift` in the app target.
2. Add `PRInfo.State.statusColor` extension.
3. Update `WorktreeRow` to consume `PRBadge?`.
4. Update `SidebarView` to pass `PRBadge?`.
5. Delete `PRButton.mergedText`, update its call site.
6. Update `WorktreeRowIconTests` (or add new test file) to cover the new rendering.
7. Update `SPECS.md`.

No other call sites reference `hasPR` — grep confirms `hasPR` only lives in `SidebarView` → `WorktreeRow` → `WorktreeRowIcon`.

## 9. Out of Scope

Restated:

- `.closed` state (red). Will land in a separate spec that also extends `GitHubPRFetcher` and `GitLabPRFetcher` to query closed-unmerged PRs as a third fallback.
- Right-click context menu on the sidebar badge.
- Keyboard shortcut to open the PR for the selected worktree.
- Showing the PR title inline in the sidebar (width is constrained; the breadcrumb pill carries the title).
