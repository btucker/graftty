# Ghostty Keybind Parity — Design Specification

Make Espalier honor the user's Ghostty keybind configuration so that every
default Ghostty shortcut — and every customization in the user's `config`
file — drives the equivalent Espalier behavior. `Cmd+D` splitting a pane,
`Cmd+Opt+Arrow` navigating between splits, `Cmd+Shift+Return` toggling
zoom: whatever chord the user has bound in Ghostty's config should produce
the matching action in Espalier, without Espalier duplicating the keybind
table.

## Multi-Spec Context

This is the first of three planned specs addressing "support all the
keyboard shortcuts that Ghostty.app does":

- **Spec 1 (this spec):** config-driven keybind plumbing; dispatch for
  every Ghostty apprt action that maps to Espalier's existing pane model;
  two new pane-layout actions (`toggle_split_zoom`, `resize_split`).
- **Spec 2 (future):** command palette. Needs its own UX design (fuzzy
  ranking, action naming, visual treatment). Depends on the dispatch layer
  from spec 1.
- **Spec 3 (future):** quick terminal. Separate window lifecycle, its own
  persistence story.

Specs 2 and 3 are out of scope here, but spec 1's dispatch layer is
deliberately shaped so they can plug into it without refactoring.

## Goal

After this spec ships, these user stories work:

> I open my `~/Library/Application Support/com.mitchellh.ghostty/config`
> and set `keybind = super+shift+n=new_split:right`. I relaunch Espalier.
> `Cmd+Shift+N` now splits the focused pane to the right, and the "Split
> Horizontally" menu item in the menu bar shows `⇧⌘N` as its hint.

> I'm deep in a 4-way split. I press `Cmd+Shift+Return` — the focused
> pane zooms to fill the worktree, siblings hide. Press it again, the
> split tree restores. My focus and scrollback are unchanged.

> I press `Cmd+Opt+Shift+Right`. The horizontal divider to the right of
> my focused pane moves ~20 pixels rightward. I keep pressing it; it
> stops at 90% of the split. I press the left-ward variant and the
> divider reverses direction.

All chords above are Ghostty's defaults (or trivial rebinds thereof).
None are hardcoded in Espalier.

## Architecture

One new unit — a **keybind bridge** — plus extensions to the existing
`handleAction` dispatch and the `SplitTree` model.

```
User presses Cmd+D  ─┐
                     │
SurfaceNSView.keyDown ──► ghostty_surface_key ──► libghostty reads config ──► action_cb
                                                                                │
SwiftUI menu click   ──► .onClick closure ────────────────────────────────────► TerminalManager.handleAction
                                                                                │
                                                                                ├── new_split:* ──► onSplitRequest ──► EspalierApp.splitPane
                                                                                ├── close_surface ──► onCloseRequest ──► EspalierApp.closePane
                                                                                ├── goto_split:* ──► setFocus
                                                                                ├── toggle_split_zoom ──► SplitTree.toggleZoom
                                                                                └── resize_split ──► SplitTree.resizing
```

`EspalierApp.commands` renders menu items whose `.keyboardShortcut(...)`
comes from the keybind bridge, not hardcoded strings. Non-menu actions
reach `handleAction` via the action-callback path and never touch AppKit's
menu dispatch.

The important property: **the dispatch code (the switch inside
`handleAction`) is the single source of truth for what each action does**.
Menu click closures call into the same dispatch. There is no parallel
Espalier-side keymap to maintain.

## Components

### New — `Sources/Espalier/Terminal/GhosttyKeybindBridge.swift`

```swift
/// Resolves chords from the user's Ghostty config for the subset of
/// actions Espalier exposes as menu items.
///
/// Rebuilt whenever the config reloads (reload_config action).
@MainActor
final class GhosttyKeybindBridge {
    /// Actions Espalier cares about for menu-shortcut bridging. Not all
    /// handleAction cases appear here — only actions that also have a
    /// CommandMenu representation.
    enum Action: String, CaseIterable {
        case newSplitRight = "new_split:right"
        case newSplitLeft  = "new_split:left"
        case newSplitUp    = "new_split:up"
        case newSplitDown  = "new_split:down"
        case closeSurface  = "close_surface"
        case gotoSplitLeft  = "goto_split:left"
        case gotoSplitRight = "goto_split:right"
        case gotoSplitUp    = "goto_split:top"
        case gotoSplitDown  = "goto_split:bottom"
        case toggleSplitZoom = "toggle_split_zoom"
        case equalizeSplits  = "equalize_splits"
    }

    init(config: ghostty_config_t)
    subscript(action: Action) -> KeyboardShortcut? { ... }
}
```

Implementation:

1. For each `Action`, call
   `ghostty_config_trigger(config, name.utf8CString, count)`. The returned
   `ghostty_input_trigger_s` carries a `ghostty_input_key_e` and a
   `ghostty_input_mods_e` bitfield, or a marker meaning "no binding."
2. Translate via `Trigger → KeyboardShortcut` helper
   (`Sources/Espalier/Terminal/KeyEquivalentFromTrigger.swift`).
3. Cache in `[Action: KeyboardShortcut]`.

Lookup failures (no binding, or unmapped key enum) return `nil` →
menu item just omits the shortcut hint.

### New — `Sources/Espalier/Terminal/KeyEquivalentFromTrigger.swift`

Pure translator:

```swift
func keyboardShortcut(from trigger: ghostty_input_trigger_s) -> KeyboardShortcut?
```

Two internal helpers:

- `KeyEquivalent` from `ghostty_input_key_e`: a finite switch table over
  ~100 key enum values (`GHOSTTY_KEY_A`..`GHOSTTY_KEY_Z`, digits,
  `GHOSTTY_KEY_ARROW_LEFT`..etc., `GHOSTTY_KEY_F1`..`F24`, punctuation,
  `GHOSTTY_KEY_RETURN`, `TAB`, `SPACE`, `ESCAPE`, `BACKSPACE`, `DELETE`).
  Unmapped keys return `nil`.
- `EventModifiers` from `ghostty_input_mods_e`: bitfield translation
  (SHIFT, CTRL, ALT, SUPER → `.shift, .control, .option, .command`).

### Modified — `Sources/Espalier/EspalierApp.swift`

- `@StateObject private var keybindBridge: GhosttyKeybindBridge` (or held
  by `TerminalManager` and surfaced via `@Published`).
- `.commands` block: each existing `.keyboardShortcut(...)` call becomes
  conditional on `keybindBridge[.xxx]`. Unbound actions render the menu
  item with no shortcut hint (implementation tactic left to the plan —
  `@ViewBuilder` helper or conditional modifier).
- New menu items for actions not yet wired: `Close Other Panes`, `Zoom
  Split`, `Equalize Splits`, `Reload Ghostty Config`, navigate
  prev/next leaf. Each gets its shortcut from the bridge.

### Modified — `Sources/Espalier/Terminal/TerminalManager.swift`

Add `handleAction` cases for every action in bucket A2 (see Action
Coverage below). Cases that fan out to the host call their respective
`onSplitRequest` / `onCloseRequest` / new `onReloadConfig` closures.
Cases that mutate layout (`toggle_split_zoom`, `resize_split`,
`equalize_splits`) call back through `onSplitTreeMutation` with a
mutation enum so `EspalierApp` can update `AppState`.

### Modified — `Sources/EspalierKit/Layout/SplitTree.swift`

Add zoom state and three new mutation methods. Details in sections
"Pane Zoom" and "Split Resize" below.

## Action Coverage

Four buckets. Every keybind in Ghostty's default set lives in exactly one
bucket.

### A1. Already working — libghostty-internal, no Espalier code needed

These fire inside libghostty during `ghostty_surface_key` and never reach
Espalier's action callback. User config customizations work today because
`loadGhosttyMacOSConfigIfPresent` already feeds the user's config into
libghostty.

Listed for completeness (so we don't accidentally re-plumb):
`copy_to_clipboard`, `paste_from_clipboard`, `select_all`, `clear_screen`,
`scroll_up`, `scroll_down`, `scroll_page_up`, `scroll_page_down`,
`scroll_to_top`, `scroll_to_bottom`, `jump_to_prompt_previous`,
`jump_to_prompt_next`, `increase_font_size`, `decrease_font_size`,
`reset_font_size`, `toggle_inspector`.

### A2. New dispatch — Espalier already has the operation

Wire `handleAction` cases; query `ghostty_config_trigger` for menu
bindings where applicable.

| Action | Dispatch | Menu item |
|---|---|---|
| `new_split:right` | `onSplitRequest(id, .right)` | Split Right (existing, rewording current "Split Horizontally") |
| `new_split:left` | `onSplitRequest(id, .left)` | Split Left (new) |
| `new_split:down` | `onSplitRequest(id, .down)` | Split Down (existing, rewording "Split Vertically") |
| `new_split:up` | `onSplitRequest(id, .up)` | Split Up (new) |
| `close_surface` | `onCloseRequest(id)` | Close Pane (existing) |
| `goto_split:left/right/top/bottom` | `navigatePane(direction)` → `setFocus` | Navigate Left/Right/Up/Down (existing) |
| `goto_split:previous/next` | traverse leaves in tree-order | Previous/Next Pane (new) |
| `equalize_splits` | `SplitTree.equalizing()` on focused worktree | Equalize Splits (new) |
| `reload_config` | reload Ghostty config, rebuild `GhosttyKeybindBridge`, notify SwiftUI | Reload Ghostty Config (new, under Espalier menu) |
| `present_terminal` | `setFocus(terminalID)` | — (action-only; fired when libghostty wants a specific surface focused) |

### A3. New dispatch + new model work

Two pane-layout features that require extensions to `SplitTree`. Detailed
in the next two sections.

| Action | Dispatch | Menu item |
|---|---|---|
| `toggle_split_zoom` | `SplitTree.togglingZoom(at: focusedID)` | Zoom Split (new) |
| `resize_split` | `SplitTree.resizing(target:direction:pixels:bounds:)` | — (chord-only; no menu entry, matches Ghostty) |

### A4. Silent no-op — registered in comments

These actions correspond to Ghostty concepts Espalier doesn't model. User
may have them bound in their config; pressing the chord does nothing. No
menu entry, no case in `handleAction` (falls into `default: break`).
Comment in the switch documents each so future readers know we looked at
them.

Tabs: `new_tab`, `move_tab`, `close_tab`, `{next,previous,last}_tab`,
`goto_tab_{1..9}`.
Windows: `new_window`, `close_all_windows`, `toggle_window_decorations`,
`toggle_maximize`, `toggle_fullscreen`.
Overlays & chrome: `toggle_quick_terminal`, `toggle_command_palette`,
`toggle_tab_overview`, `check_for_updates`, `open_config`.
Search: `start_search`, `search_{next,previous}`, `start_search_reverse` —
deferred until Espalier has a scrollback search UI.

## Pane Zoom (`toggle_split_zoom`)

### Model change

Add zoom state to `SplitTree`:

```swift
struct SplitTree {
    let root: Node?
    let zoomed: TerminalID?   // new, nil = normal view
}
```

Ephemeral, not persisted. One zoom state per worktree (since Espalier has
one `SplitTree` per worktree). This matches upstream Ghostty's
`SplitTree.swift` where `zoomed` lives on the tree, not on any per-split
node.

### Mutation invariants

All existing `SplitTree` methods get their zoom semantics clarified. The
invariants are ported verbatim from upstream
(`macos/Sources/Features/Splits/SplitTree.swift:123-155, 250, 332`):

- **`inserting(view:at:direction:)`** always returns with `zoomed: nil`.
  Splitting from a zoomed state unzooms.
- **`removing(target:)`** returns with
  `zoomed = (zoomed == target) ? nil : zoomed`. Closing the zoomed pane
  auto-unzooms; closing a sibling preserves zoom on the survivor.
- **`resizing(...)`** (below) always returns with `zoomed: nil`.

Plus one new method:

```swift
extension SplitTree {
    /// Toggles the zoomed state for the given leaf.
    ///   - If `leaf == zoomed`, unzooms (returns tree with `zoomed: nil`).
    ///   - Else if `isSplit`, zooms that leaf.
    ///   - Else (single-leaf tree), returns `self` unchanged.
    func togglingZoom(at leaf: TerminalID) -> SplitTree
}
```

### Navigation while zoomed

Default behavior: **unzoom-then-navigate**. `goto_split:*` while
`zoomed != nil` first clears zoom, then runs the normal navigation
algorithm over the full tree. Matches Ghostty's
`BaseTerminalController.swift:640-652`.

Ghostty 1.3 added a `split-preserve-zoom = navigation` config flag that
instead transfers zoom to the newly-focused leaf. We honor this flag
(query once at startup via `ghostty_config_get`, re-query on
`reload_config`). In code:

```swift
// pseudocode inside handleAction for goto_split actions:
let next = navigateTarget(from: focused, direction: dir, in: tree)
let newTree: SplitTree
if tree.zoomed != nil, config.splitPreserveZoomOnNavigation {
    newTree = tree.withZoomed(next)   // transfer zoom to next
} else if tree.zoomed != nil {
    newTree = tree.withZoomed(nil)    // unzoom
} else {
    newTree = tree
}
```

### Rendering

`SplitTreeView` (or whatever wraps the split tree root) branches once at
the top:

```swift
if let zoomed = tree.zoomed {
    SurfaceView(terminalID: zoomed)
} else {
    SplitTreeView(tree: tree, focused: ...)
}
```

**Surfaces are not torn down during zoom/unzoom.** `TerminalManager`
still owns every `SurfaceHandle` by `TerminalID`; SwiftUI just chooses
which to mount. Hidden surfaces keep their last-known size because
SwiftUI doesn't lay them out while they're off-tree, so
`ghostty_surface_set_size` doesn't fire. On unzoom, SwiftUI re-lays out
the tree and normal `setFrameSize` resumes. No flicker, no scrollback
loss, no `.reload()` needed.

## Split Resize (`resize_split`)

### Payload

From libghostty (`include/ghostty.h:595-606`,
`src/apprt/action.zig:532-545`):

```c
typedef struct {
  uint16_t amount;
  ghostty_action_resize_split_direction_e direction;  // UP | DOWN | LEFT | RIGHT
} ghostty_action_resize_split_s;
```

`amount` is **pixels**.

### Target resolution

Walk up from the focused leaf to the nearest split ancestor whose
orientation matches the direction:

- `UP` or `DOWN` → nearest `.vertical` ancestor (horizontal divider;
  splits into top/bottom).
- `LEFT` or `RIGHT` → nearest `.horizontal` ancestor (vertical divider;
  splits into left/right).

If no matching ancestor exists (e.g., three horizontal splits, user
presses `UP`), log at debug and no-op — Ghostty's
`BaseTerminalController.swift:715-717` does the same.

### New SplitTree operation

```swift
extension SplitTree {
    /// Resize a split ancestor of `target` by `pixels` in the given
    /// direction. Walks up to the nearest matching-orientation ancestor;
    /// throws `SplitError.viewNotFound` if none exists.
    ///
    /// The ratio is clamped to [0.1, 0.9] — matching Ghostty upstream —
    /// so no pane can reach zero width/height.
    ///
    /// Always returns with `zoomed: nil` (resize unzooms).
    ///
    /// - Parameters:
    ///   - target: the focused leaf whose ancestor we resize.
    ///   - direction: UP / DOWN / LEFT / RIGHT.
    ///   - pixels: the signed(ish) offset; direction carries the sign.
    ///   - ancestorBounds: the current pixel size of the ancestor split
    ///     (provided by the call site, which reads it from the view
    ///     layout). Used to convert pixels → ratio delta.
    func resizing(
        target: TerminalID,
        direction: ResizeDirection,
        pixels: UInt16,
        ancestorBounds: CGRect
    ) throws -> SplitTree
}
```

**Why `ancestorBounds` is a parameter** (not looked up internally):
`SplitTree` is a pure model; it doesn't know its rendered pixel size.
Ghostty does the equivalent — `SplitTree.resizing` takes the split's
pixel-size slot. The call site (inside `EspalierApp` or `TerminalManager`)
reads bounds from the SwiftUI layout and passes them in. This keeps
`SplitTree` layout-independent and testable without a renderer.

### Dispatch

```swift
case GHOSTTY_ACTION_RESIZE_SPLIT:
    guard let id = terminalID(from: target) else { return }
    let resize = action.action.resize_split
    let direction = ResizeDirection(from: resize.direction)
    onResizeSplit?(id, direction, resize.amount)
```

`EspalierApp` resolves `ancestorBounds` from the current layout (stored
per-worktree in `@State` indexed by split-node id) and calls
`tree.resizing(...)` with the full argument list. If `throws`, log +
no-op.

### Clamping

Fixed `[0.1, 0.9]` ratio bounds, matching upstream
`SplitTree.swift:307-316`. Further resizes past the boundary silently
saturate (no overflow, no error).

## Error Handling & Fallbacks

- **Unknown `GHOSTTY_ACTION_*` value** → `default: break`. libghostty
  version bumps add new action enum values without breaking us; we handle
  them in follow-ups.
- **`ghostty_config_trigger` reports no binding for an action** → menu
  item omits the `.keyboardShortcut(...)` modifier. Entry still clickable.
- **Unmapped `ghostty_input_key_e` in the translator** → same treatment.
  Log once at debug with the unknown enum value so missing translations
  surface in development.
- **`SplitTree.resizing(...)` throws** → log at debug, no-op. Matches
  Ghostty's behavior.
- **`toggle_split_zoom` on a non-split tree** → silent no-op (`isSplit`
  guard inside `togglingZoom`).
- **`reload_config`** → rebuild `GhosttyKeybindBridge`, post
  a notification that triggers SwiftUI to recompute `.commands`. If the
  user removed a `keybind = ...` line, the previously-bridged menu item
  loses its shortcut hint. No reboot required for this case.

## Testing

Existing constraint: the `Espalier` app target has no test target. Tests
live in `EspalierKitTests` (model layer) or as manual smoke checks.

### Automated — in `EspalierKitTests`

- **`KeyEquivalentFromTriggerTests`**: exhaustive table test covering
  every `ghostty_input_key_e` we care about. Assert
  `translate(GHOSTTY_KEY_D, SUPER) == KeyboardShortcut("d",
  modifiers: .command)`, etc. Include one "unmapped key enum" case
  asserting `nil`.
- **`SplitTreeZoomTests`**: assert the invariants from "Mutation
  invariants" above. Three cases for each of `inserting`, `removing`:
  (1) no zoom → zoom unchanged, (2) zoom on target → auto-unzoom,
  (3) zoom on sibling → zoom preserved.
- **`SplitTreeResizeTests`**: test pixel→ratio conversion against known
  bounds; test clamping at 0.1 and 0.9; test `.viewNotFound` throw when
  no matching-orientation ancestor; test returned tree has `zoomed: nil`.
- **`SplitTreeTogglingZoomTests`**: three cases — zoom a leaf, re-zoom
  same leaf (unzoom), zoom on non-split tree (no-op).
- **`GhosttyKeybindBridgeTests`**: pin down action-name strings. Inject
  a fake trigger-resolver closure so tests don't need a real
  `ghostty_config_t`. Assert each `Action.rawValue` matches the string
  Ghostty accepts in its config.

### Manual smoke checklist

Captured in the final commit of the implementation plan. Covers:

1. Open a pane. Press every in-scope Ghostty default chord. Observe the
   expected behavior (split, close, navigate, zoom, resize, equalize,
   reload config).
2. Add `keybind = super+shift+x=close_surface` to
   `~/Library/Application Support/com.mitchellh.ghostty/config`.
   Restart Espalier. Verify (a) `Cmd+Shift+X` closes the focused pane,
   (b) the Close Pane menu item shows `⇧⌘X`.
3. Zoom a pane. Verify only that pane visible, siblings hidden. Unzoom;
   verify split tree restores without flicker or scrollback loss.
4. In a 3-way split (horizontal over vertical), press `resize_split`
   rightward repeatedly. Verify only the inner vertical divider moves;
   the outer horizontal is untouched. Hit 90% clamp; verify saturation.
5. Press a tab chord (`Cmd+T`) and a window chord (`Cmd+N`) with their
   Ghostty-default bindings. Verify no crash, no UI flash, no change.
6. Press a `resize_split` chord when the focused pane has no matching
   ancestor. Verify debug log + no-op.

## SPECS.md Additions

Add a new section §14 (after §13 zmx):

```
## §14 Keyboard Shortcuts

**KBD-1.1** When the user presses a chord bound in their Ghostty config
to an apprt action Espalier supports, the application shall dispatch
that action.

**KBD-1.2** When the user's Ghostty config omits a binding for an action,
the corresponding Espalier menu item shall render without a shortcut hint
but remain clickable.

**KBD-2.1** When the user presses `toggle_split_zoom` on a focused pane
inside a split tree, the application shall render only that pane and
keep all surfaces alive at their current size.

**KBD-2.2** When the user presses `toggle_split_zoom` on a lone pane
(tree has no siblings), the application shall no-op.

**KBD-2.3** When the user presses a `goto_split:*` chord while a pane is
zoomed and `split-preserve-zoom` does not include `navigation`, the
application shall unzoom before navigating.

**KBD-3.1** When the user presses a `resize_split:<direction>` chord,
the application shall walk up from the focused leaf to the nearest
split ancestor with matching orientation and adjust its ratio by
`amount` pixels, clamped to [0.1, 0.9].

**KBD-3.2** When no matching-orientation ancestor exists, the
application shall log at debug and no-op.

**KBD-4.1** When `reload_config` fires, the application shall rebuild
its Ghostty-config-derived menu shortcuts without requiring a restart.
```

## Out of Scope (Deferred)

- Command palette UI (spec 2).
- Quick terminal window (spec 3).
- Scrollback search (`start_search` etc.). Deferred until Espalier has
  a search UI.
- Espalier-specific chord customization (a user wanting an Espalier-only
  shortcut that Ghostty doesn't know about). Not needed for parity with
  Ghostty; tracked separately if requested.
- Per-worktree or per-pane keybind scoping. Ghostty's config is
  application-scoped; matching that.
- "Close other panes" and "equalize splits" chords — Ghostty has
  `close_all_splits_in_window` analogous, but we're adding the menu item
  without a shortcut for now since there's no Ghostty default chord for
  our worktree-scoped variant.

## Open Questions (Pre-Implementation)

None. Every design decision above has a cited upstream reference or an
explicit rationale. If implementation hits an ambiguity, it becomes a
plan-level decision, not a spec revision.
