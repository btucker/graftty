# Ctrl+Tab attention-first worktree navigation

## Goal

In the Mac app, `ctrl+tab` should jump to the next worktree that has
**requested attention**. If no worktree currently has attention, it falls
through to plain next-worktree navigation. `ctrl+shift+tab` is the reverse
(previous attention worktree, else previous worktree).

Today there is no worktree-level keyboard navigation at all — only
pane-within-worktree cycling (`goto_split:previous/next`, KBD-2.3). This adds
worktree cycling as a sibling under the existing KBD (keybind) feature.

## Behavior

On `ctrl+tab` (forward) / `ctrl+shift+tab` (reverse):

1. Build the ordered list of **selectable** worktrees in sidebar order — the
   flattening of `AppState.repos[]` × `repo.worktrees[]`, restricted to
   worktrees with an on-disk checkout (`state.hasOnDiskWorktree` — i.e.
   `.closed` / `.running`). Rows that are `.stale` / `.creating` / `.deleting`
   are skipped: they have no focusable directory (the existing
   `selectWorktree` refuses `.creating`) and can't carry agent attention.
2. Compute the **attention subset**: worktrees where
   `attention != nil || !paneAttention.isEmpty` — any `AttentionSource`
   (`agentStop`, `userNotify`, `commandFinished`), worktree-level or per-pane —
   **excluding the currently-selected worktree**.
3. **If the attention subset is non-empty:** the target is the next worktree in
   that subset in cyclic order from the current selection's position
   (forward or reverse per the chord).
4. **Else:** the target is the next selectable worktree in cyclic order from
   the current selection.
5. Selecting the target runs the existing `MainWindow.selectWorktree`, which
   already calls `acknowledgeAttention()` — clearing that worktree's
   attention on arrival. So repeated `ctrl+tab` walks through every attention
   worktree (each cleared as it is visited), then continues as plain
   next-worktree once the attention queue drains.

### Edge cases

- **No current selection** (`selectedWorktreePath == nil`): treat as "before
  the first" — forward picks the first attention worktree (else the first
  selectable worktree); reverse picks the last.
- **0 or 1 selectable worktrees:** no-op (nothing to move to).
- **Current worktree carries attention** (a ping arrived while it was
  focused): it is never a jump target — it's excluded from the attention
  subset (step 2) and, being the current selection, is not "next." It is
  acknowledged normally the next time it is selected.
- **Wrap-around:** cyclic in both the attention subset and the full selectable
  list.

## Structure

Three layers, following existing patterns.

### 1. Pure selection logic — `GrafttyKit` (unit-tested)

A pure function on `AppState`:

```swift
extension AppState {
    /// Returns the worktree path `ctrl+tab` (forward) / `ctrl+shift+tab`
    /// (reverse) should select next, or nil if there is nothing to move to.
    /// Attention worktrees (any source, worktree- or pane-level), excluding
    /// the current selection, take priority; otherwise plain cyclic
    /// next/previous over on-disk worktrees in sidebar order.
    func nextWorktreePath(forward: Bool) -> String?
}
```

No UI, no side effects — the RED/GREEN test target, mirroring
`WorktreeEntryAttentionTests`. Reuses the existing
`indices(forWorktreePath:)` helper to locate the current position.

### 2. Keybind action — `GhosttyAction`

Two new cases so the shortcut resolves through the existing bridge and stays
rebindable via Ghostty config (identical to `goto_split:*`):

```swift
case nextTab     = "next_tab"       // Ghostty default: ctrl+tab
case previousTab = "previous_tab"   // Ghostty default: ctrl+shift+tab
```

`GhosttyAction` raw values are pinned by tests; the new cases get their pins.

### 3. UI wiring — `Graftty` app target

- **New FocusedValue** (`WorktreeNavFocusedValues.swift`), mirroring
  `AddWorktreeFocusedValues.swift`: `MainWindow` publishes a
  `(_ forward: Bool) -> Void` closure. The `.commands` block (which can't
  reach view-local state) invokes it. `nil` when there is no window / nothing
  selectable → menu items disabled.
- **`MainWindow`** implements the closure as:
  `if let p = appState.nextWorktreePath(forward: forward) { selectWorktree(p) }`
  — routing through the same `selectWorktree` used by sidebar clicks so
  surface show/hide, surface creation, and attention-ack all behave
  identically.
- **`GrafttyApp.commands`**: two `bridgedButton`s — "Next Worktree"
  (`.nextTab`) and "Previous Worktree" (`.previousTab`) — under a new
  `Divider()` in the existing navigation `CommandGroup`, alongside the
  pane-nav items.

## Requirements (KBD-5.x)

New specs under the KBD prefix (KBD 1–4 exist; KBD already owns keybind-driven
navigation including `goto_split`):

- **KBD-5.1** — When the user presses `next_tab` and one or more other on-disk
  worktrees have attention, the application shall select the next
  attention-carrying worktree in cyclic sidebar order.
- **KBD-5.2** — When the user presses `next_tab` and no other worktree has
  attention, the application shall select the next on-disk worktree in cyclic
  sidebar order.
- **KBD-5.3** — When the user presses `previous_tab`, the application shall
  apply KBD-5.1 / KBD-5.2 selection in reverse cyclic order.
- **KBD-5.4** — Attention for worktree navigation shall count any attention
  source (agent-stop, user notify, command-finished), at either worktree or
  pane scope, and shall exclude the currently-selected worktree from the
  attention subset.
- **KBD-5.5** — When zero or one on-disk worktree is selectable, `next_tab` /
  `previous_tab` shall be a no-op.
- **KBD-5.6** — When no worktree is selected, `next_tab` shall select the first
  attention worktree (else the first on-disk worktree), and `previous_tab` the
  first attention worktree scanning backward from the end (else the last
  on-disk worktree) — attention-first applies uniformly in both directions.

Each gets a real `@Test` in a dedicated `KbdWorktreeNavTests.swift` after
being promoted from a `.disabled` entry in `KbdTodo.swift`. `GhosttyAction`
raw-value pin tests extend the existing keybind action-string test.

## Testing

- **Pure logic (Swift Testing, GrafttyKit):** table-driven cases over
  `nextWorktreePath(forward:)` — attention subset present/absent, forward and
  reverse, wrap-around, current-has-attention excluded, no-selection start,
  0/1 worktree no-op, attention spanning multiple repos.
- **Action pins:** `next_tab` / `previous_tab` raw strings.
- UI wiring (FocusedValue + bridgedButton) is thin glue over the tested pure
  function and the already-tested `selectWorktree`; no new UI test harness.

## Out of scope

- Rebinding UI beyond what Ghostty config already provides.
- Any change to how attention is set or auto-cleared.
- iPad/web surfaces (this is a Mac-app keyboard feature).
