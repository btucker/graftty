# iPad Hardware Shortcut Responder Design

## Problem

iPad app commands such as `Cmd+D` and `Ctrl+Tab` do not work while a hardware
keyboard is connected and the terminal is active. Holding Command also omits
the expected Split Right command from the iPadOS shortcut overlay.

The active terminal uses `TerminalSoftwareKeyboardProxyView`, a `UIKeyInput`
child view, as first responder. App-level `UIKeyCommand` values currently live
on its parent `TerminalInputContainerView`. The command list is populated and
filtered after asynchronous host, pane-control, and worktree state changes,
but replacing the backing array does not prompt UIKit to rebuild its
key-command table. Existing tests read the computed `keyCommands` property
directly, so they do not exercise this lifecycle.

There is a separate shortcut-model gap for worktree navigation. Ghostty has
multiple default chords for next and previous tab, including `Ctrl+Tab` and
`Ctrl+Shift+Tab`, but the bundled mobile fallback retains only one chord per
action and currently selects the `Cmd+Shift+]` and `Cmd+Shift+[` aliases.

## Goals

- Make app-level iPad shortcuts available while terminal input owns first
  responder status.
- Make late command installation and subsequent enablement changes visible to
  UIKit without remounting or refocusing the terminal.
- Support `Cmd+D` for Split Right and `Ctrl+Tab` / `Ctrl+Shift+Tab` for
  worktree navigation under the bundled Ghostty defaults.
- Preserve host-resolved Ghostty shortcuts and terminal input behavior.
- Keep general terminal key translation owned by libghostty.

## Non-Goals

- Reimplementing terminal key translation with `pressesBegan` or raw HID
  events.
- Adding iPad behavior for Ghostty commands that remain unsupported in the
  shared command registry.
- Adding visible shortcut settings or changing the Mac command system.
- Treating disabled commands as terminal input when their chord is reserved by
  an enabled app-level command in another state.

## Design

### Command Ownership

`TerminalSoftwareKeyboardProxyView`, the actual first responder, will publish
the active app-level `UIKeyCommand` table. `TerminalInputContainerView` remains
the integration boundary used by `TerminalPaneView`, but forwards command
descriptors to the proxy instead of overriding `keyCommands` itself.

The proxy will continue to implement `UIKeyInput` for ordinary software
keyboard text. Its command table contains only application-level Ghostty
actions prepared by `MobileGhosttyCommandButtons.hardwareKeyboardCommands`.
All other physical-keyboard input continues through libghostty's existing
terminal path.

### Dynamic Updates

Command assignment is main-actor isolated. Assigning a command list to the
proxy will first replace the backing descriptor list, then compare the new
command identities, titles, inputs, and normalized modifiers with the
previously published list. When the effective table changes, the proxy will
synchronously request a main-menu-system rebuild by calling
`UIMenuSystem.main.setNeedsRebuild()` after the backing descriptors and
effective signature are updated. Current UIKit exposes no responder-level
key-command invalidation API; the rebuild request is the supported way to make
UIKit query the responder's `keyCommands` again. This covers:

- the initial empty-to-populated transition after host keybindings load;
- pane-control availability changing Split and Close enablement;
- worktrees or pane layout changing navigation enablement;
- host switching or refreshed host bindings replacing chords; and
- commands becoming disabled and being removed.

Command closures are updated even when the effective signature is unchanged,
so dispatch always observes the current iPad selection and environment. Title
participates in that signature because UIKit displays it through both `title`
and `discoverabilityTitle`. A menu-system rebuild request is needed only when
the effective key-command table changes.

### Multiple Chords Per Action

The mobile fetch boundary will return a `MobileGhosttyKeybindingSet` containing
both a `GhosttyKeybindBridge` and explicit provenance:

- `.loading` contains the empty bridge while a selected host is refreshing;
- `.hostResolved` contains a successfully decoded host response, including a
  valid response whose binding dictionary is empty; and
- `.bundledFallback` contains bundled defaults after a missing endpoint,
  non-success response, transport failure, or decode failure.

The cache stores and returns the full set rather than only its bridge, and
`IPadRootLayout` passes the full set into `MobileGhosttyCommandContext`. No code
will infer provenance by comparing chord dictionaries.

The command construction boundary will allow more than one hardware command
descriptor to invoke the same `GhosttyAction`. A `.hostResolved` set publishes
only its authoritative configured chord for each action. A
`.bundledFallback` set may add known Ghostty aliases for the same action. A
`.loading` set publishes no commands.

For the initial fix, the fallback table will expose:

- Next Worktree: `Ctrl+Tab` and `Cmd+Shift+]`.
- Previous Worktree: `Ctrl+Shift+Tab` and `Cmd+Shift+[`.

Aliases must have stable unique descriptor identifiers derived from both the
action and chord. Dispatch will continue to match input plus normalized
application modifiers, so both aliases reach the same semantic action.

Host configuration must not be silently expanded with fallback aliases when a
host explicitly resolves a different chord for the action. Fallback aliases
apply only when provenance is `.bundledFallback`. This preserves the user's
Ghostty configuration as the source of truth.

Descriptors are deduplicated by normalized input and modifiers. Host-resolved
descriptors are never mixed with bundled aliases. Within the fallback set, the
primary chord in `GhosttyDefaultKeybinds.chords` wins over an alias on
collision; remaining alias collisions are resolved in shared registry order.

### Enablement and Precedence

Only currently enabled commands are published. Split and Close require a
focused pane and pane-control client. Pane navigation requires a valid target.
Worktree navigation requires at least two selectable worktrees.

Published app commands take precedence over terminal input for exact input and
modifier matches. Disabled or absent commands are not published, leaving the
chord available to the rest of the responder chain and terminal.

## Data Flow

1. Host selection synchronously installs `.loading` with an empty bridge so
   stale shortcuts from the previous host are removed during refresh.
2. The fetch/cache layer asynchronously returns `.hostResolved` on a valid
   response or `.bundledFallback` on failure.
3. `IPadRootLayout` creates a semantic command context containing the full
   keybinding set, execution closure, and current enablement closure.
4. `MobileGhosttyCommandButtons` expands the context into hardware command
   descriptors, including fallback aliases when applicable.
5. `TerminalPaneView.updateUIView` assigns the descriptors through
   `TerminalInputContainerView` to the active keyboard proxy.
6. The proxy detects table changes, requests a main-menu-system rebuild, and
   publishes fresh `UIKeyCommand` objects from its `keyCommands` override.
7. UIKit invokes the proxy action for a matching hardware chord. The proxy
   resolves the descriptor by input and normalized modifiers and calls its
   semantic action closure.

## Error Handling

- Empty, untranslatable, unsupported, and disabled commands are omitted.
- Duplicate chord descriptors follow the precedence rule above so UIKit does
  not receive ambiguous commands.
- A dispatched command that no longer matches the current descriptor table is
  ignored.
- Pane-control failures retain the current behavior: the host snapshot remains
  authoritative and the command does not mutate local layout optimistically.
- If the host keybinding fetch fails, bundled defaults and aliases remain
  active.

## Testing

### Responder Lifecycle

- A proxy starting with no commands publishes no key commands.
- Installing `Cmd+D` after initialization marks the command table for update
  and publishes Split Right from the first responder.
- Reassigning an equivalent table does not request an unnecessary rebuild.
- Changing identity, title, input, modifiers, or enablement synchronously
  requests a rebuild for the replacement table.
- Dispatch from the proxy invokes only the exact normalized chord match.

The rebuild request will be exposed through a narrow test observation seam,
because simulator unit tests cannot make UIKit disclose its private command
table directly. The test must exercise assignment on the responder rather than
calling a parent computed property.

### Command Construction

- Bundled defaults generate both `Ctrl+Tab` and `Cmd+Shift+]` for Next
  Worktree.
- Bundled defaults generate both `Ctrl+Shift+Tab` and `Cmd+Shift+[` for
  Previous Worktree.
- `Cmd+D` generates Split Right.
- A host-resolved custom chord replaces fallback aliases for that action.
- A successfully fetched empty host binding set remains `.hostResolved` and
  does not gain fallback aliases.
- Fetch failures return `.bundledFallback`, while host refresh begins with
  `.loading`; cache hits retain their original provenance.
- Disabled commands produce no responder command.

### Regression Coverage

- Existing software-keyboard focus, terminal gesture, selection, paste, and
  responder tests remain green.
- iOS simulator tests cover the command-construction and responder lifecycle
  paths.
- Package tests cover any pure shortcut-alias representation introduced in the
  shared protocol target.

## Specification Changes

`IPAD-9.9` will be tightened to require the actual terminal input responder to
publish commands and synchronously request a UIKit menu-system rebuild when the
effective command set changes.

`IPAD-9.10` will require mobile keybinding fetch/cache results to retain
`.loading`, `.hostResolved`, or `.bundledFallback` provenance and will require
the bundled fallback to retain the standard `Ctrl+Tab` and `Ctrl+Shift+Tab`
worktree-navigation aliases in addition to the Command-bracket aliases.
