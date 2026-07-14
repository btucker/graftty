# iPad Ghostty Keyboard Commands — Design Specification

## Goal

Make Graftty on iPad honor the same host-resolved Ghostty command keybindings
that Graftty on Mac uses for pane and worktree commands when a hardware keyboard
is attached. The iPad should feel like the same workstation: if the user's
Ghostty config binds a supported app-level action, that chord should drive the
equivalent iPad command rather than being hardcoded separately or ignored.

This spec is a first pass focused on commands whose iPad semantics are already
clear. It deliberately defers commands that would require new product decisions
about whether iPad should mutate shared host layout state beyond split/close or
perform Mac-local configuration actions.

## Current Context

Mac command parity is already driven by `GhosttyKeybindBridge` and
`GhosttyAction`. `GrafttyApp.commands` asks the bridge for the user's configured
chord and renders menu buttons for actions such as split, pane focus,
worktree navigation, zoom, equalize, and close. Mac menu shortcuts intercept
matching chords before the terminal receives them, so app commands win over
terminal input when the app has registered the chord.

iPad currently has a narrower, one-off implementation. `IPadRootLayout` installs
hidden SwiftUI buttons for `Ctrl+Tab` and `Ctrl+Shift+Tab` worktree navigation,
while pane split and close are exposed through visible iPad UI backed by
`PaneEnvironment` and the `pane-control` channel. This means iPad does not
share the Mac keybinding source of truth and cannot follow a user's Ghostty
config customizations for supported app-level commands.

The mobile `pane-control` protocol currently supports remote split and close
requests. iPad also has local access to the current `PaneLayoutNode` tree through
the panes-state path, which is enough to compute local focus movement without
mutating the host layout.

## Design

### 1. Shared command registry

Introduce a shared command registry that describes the app-level Ghostty actions
Graftty can expose through platform command surfaces. Each entry shall include:

- the `GhosttyAction`;
- a user-facing label;
- a semantic command kind, such as split, close pane, focus pane, next/previous
  pane, or next/previous worktree;
- platform availability.

Mac and iPad shall both consume this registry rather than maintaining separate
lists of command actions. Mac keeps its existing execution closures and menu
placement. iPad installs an equivalent hidden command surface for hardware
keyboard invocation.

The registry is not a promise that every Ghostty action works everywhere. It is
the shared catalog of app-level actions Graftty understands, with per-platform
availability deciding what each platform registers.

### 2. Shared shortcut translation

The shortcut conversion from `ShortcutChord` to SwiftUI `KeyboardShortcut` shall
be shared by Mac and iPad. Unsupported or untranslatable chords shall return
`nil`; platforms shall omit or disable that command binding rather than falling
back to hardcoded defaults.

iPad command chords shall come from the host-resolved Ghostty keybinding bridge,
not from iPad-specific defaults. If the host Ghostty config changes and the
mobile app receives updated resolved keybindings through the same data path used
for theme/config state, iPad should rebuild its command surface from those
bindings.

### 3. iPad command execution

iPad shall support these command kinds in the first pass:

- `new_split:right`
- `new_split:down`
- `new_split:left`
- `new_split:up`
- `close_surface`
- `goto_split:left`
- `goto_split:right`
- `goto_split:up`
- `goto_split:down`
- `goto_split:previous`
- `goto_split:next`
- `next_tab`
- `previous_tab`

Split commands shall call the same pane-control split path used by the iPad
toolbar, targeting the current `focusedPaneId`.

Close shall call the pane-control close path for the current `focusedPaneId`.

Directional focus commands shall match Mac `TERM-7.3` semantics. From the
focused leaf, the resolver walks up the split tree to the nearest ancestor whose
split orientation matches the requested motion axis and whose source-side
subtree contains the focused leaf, then descends into the opposite subtree's
near-edge leaf. If no such ancestor exists, the command is a no-op; directional
focus shall not wrap through unrelated panes. iPad may implement this directly
for `PaneLayoutNode` or use a shared adapter, but the observable behavior must
match Mac `SplitTree.spatialNeighbor`.

Previous/next pane commands shall match Mac tree-order navigation semantics.
They traverse the current worktree's `PaneLayoutNode.leaves` sequence, which is
an in-order/DFS left-to-right flattening of the split tree, and wrap around at
the ends. Zero or one leaf is a no-op. This sequence is intentionally separate
from directional spatial focus.

Next/previous worktree commands shall use the same attention-first worktree
navigation rule already specified for iPad active-workstation behavior. This
replaces the current hardcoded `Ctrl+Tab` overlay with the shared command
registry and host-configured keybinding.

Every successful iPad focus or worktree navigation command shall reuse the
existing iPad active-selection behavior: focus the terminal and, for iPad only,
request display ownership for the selected pane when it becomes takeable.

### 4. Command precedence

On iPad, supported app command chords shall be registered through SwiftUI's
command/keyboard shortcut layer so they execute before the keystroke reaches the
terminal view. This matches Mac menu shortcut precedence.

If a user binds a terminal-meaningful chord such as `control+a` to a supported
app-level Ghostty action, iPad shall treat it as an app command while Graftty's
iPad layout is focused. That is the expected consequence of binding the chord to
an app-level action, and it keeps Mac/iPad behavior consistent.

### 5. Unsupported commands

The first pass shall not implement these Ghostty actions on iPad:

- `toggle_split_zoom`
- `equalize_splits`
- `reload_config`
- `open_config`

`toggle_split_zoom` and `equalize_splits` are deferred because they need an
explicit decision about whether iPad should mutate shared host layout state or
apply a local-only presentation mode. `reload_config` and `open_config` are
deferred because they are Mac-local configuration commands rather than iPad pane
commands.

Unsupported actions shall not register active iPad shortcuts. They may remain in
the shared registry as Mac-only entries.

## Data Flow

### Startup/config refresh

The app resolves the host Ghostty config into a `GhosttyKeybindBridge`. Mac and
iPad consume the same `GhosttyAction` to `ShortcutChord` mapping. Each platform
then asks the shared shortcut converter for a SwiftUI `KeyboardShortcut`.

If a chord cannot be translated into SwiftUI's shortcut representation, no iPad
command shortcut is installed for that action.

### Hardware keyboard command

The user presses a hardware keyboard chord on iPad. SwiftUI matches the
registered command shortcut before terminal input dispatch. The iPad command
executor receives the semantic command kind and applies it to `IPadAppState`,
`PaneEnvironment`, and the current pane/worktree snapshots.

### Split or close

The executor sends a pane-control request to the host for the focused pane. The
host remains the source of truth. The iPad updates visible state from the next
panes-state snapshot rather than optimistically mutating the local tree.

### Focus movement

The executor computes the target pane from the latest layout snapshot using the
same semantics as Mac pane navigation. Directional commands use
`TERM-7.3`-style spatial neighbor resolution and do not wrap. Previous/next pane
commands use `PaneLayoutNode.leaves` order and wrap. When a target exists, the
executor updates `focusedPaneId` and runs the active-selection/focus request
path. No host layout mutation is sent.

## Error Handling

- Commands with no focused pane are disabled or no-ops.
- Split and close commands are disabled or no-ops when `PaneEnvironment` has no
  pane-control client.
- Untranslatable keybindings do not install fallback shortcuts.
- If the focused pane disappears before a command runs, the command is a no-op
  and the normal panes-state reconciliation chooses the next valid focus.
- Pane-control failures should use the same transient handling as toolbar
  split/close actions; the next authoritative snapshot remains the source of
  truth.
- Worktree navigation with zero or one selectable worktree is a no-op.

## Testing

### Shared command registry

- The shared registry contains the supported iPad command set and marks deferred
  actions as Mac-only or otherwise unavailable on iPad.
- Mac command rendering can still derive the same actions it currently exposes
  from the shared registry.
- Unsupported or untranslatable chords produce no `KeyboardShortcut`.

### iPad command routing

- iPad split commands map each `new_split:*` action to the matching
  pane-control split direction for the focused pane.
- iPad close maps `close_surface` to pane-control close for the focused pane.
- Directional focus commands match the existing Mac `TERM-7.3` spatial-neighbor
  cases, including uneven split trees and no-wrap behavior when no neighbor
  exists.
- Previous/next pane commands cycle through `PaneLayoutNode.leaves` order with
  wraparound and no-op for zero or one leaf.
- Next/previous worktree commands use the shared attention-first iPad worktree
  navigation rule and no longer depend on hardcoded `Ctrl+Tab` shortcuts.

### Command precedence

- Registered iPad command shortcuts are installed through SwiftUI command or
  hidden button shortcut wiring so they are app commands rather than terminal
  text input.
- Commands with missing/untranslatable bindings are not installed.

## Out of Scope

- Defining iPad semantics for zoom split or equalize splits.
- Opening or reloading Ghostty config from iPad.
- Adding new pane-control protocol operations beyond the split and close support
  already used by iPad.
- Changing iPhone compact-layout keyboard behavior.
- Adding a visible iPad command palette or menus.
- Mobile port chips or Graftty-hosted local-port proxying.
