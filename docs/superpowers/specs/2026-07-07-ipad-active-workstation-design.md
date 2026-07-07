# iPad active-workstation interaction polish

## Goal

Make Graftty on iPad regular-width layouts behave like an active workstation
rather than a passive terminal viewer. The iPad should match the Mac where that
fits the two-column model: selecting a worktree means "make this my active
pane", keyboard navigation moves between worktrees, pane lifecycle actions are
available, and the visual shell uses the same terminal-background-plus-sidebar
relationship.

This spec is deliberately scoped to iPad interaction polish. Mobile port chips
and the Graftty-hosted local-port proxy are a separate spec because they touch
wire payloads, web-server proxying, and security rules.

## Current Context

The iPad regular-width layout is `IPadRootLayout`, with `WorktreeListContent`
in the sidebar and `SingleSessionView` in the detail column. `IPadAppState`
tracks `selectedWorktreePath` and `focusedPaneId`.

Today, tapping a worktree row updates selection, but the live terminal does not
become UIKit first responder. `TerminalPaneView` only calls
`becomeFirstResponder()` when its `focusRequestCount` changes, and sidebar
selection does not change that counter. The result is a false focus state: the
sidebar and detail column show the chosen pane, but keyboard input still needs a
second tap in the terminal.

Mac already has attention-first worktree navigation via `next_tab` and
`previous_tab`. The pure rule lives in `AppState.nextWorktreePath(forward:)`:
jump to the next worktree with attention, excluding the current worktree, else
cycle through selectable on-disk worktrees in sidebar order.

The Mac Add Worktree sheet already marks Create as the default action. The iOS
Add Worktree sheet has a toolbar confirmation button, but it does not yet make
Return from a hardware keyboard submit the valid form.

## Design

### 1. iPad selection means focus and ownership

On iPad regular-width layouts, selecting a worktree row or pane child row shall:

1. Set `IPadAppState.selectedWorktreePath` to the selected worktree.
2. Set `IPadAppState.focusedPaneId` to the target pane, using the first leaf for
   a worktree-row tap.
3. Request terminal first-responder focus for the rendered `SingleSessionView`.
4. Request display ownership for that pane if the iPad is not already owner.

This is an iPad-only behavior. The iPhone compact flow keeps the explicit
Take Control model: selecting a pane navigates to it, but does not auto-take
ownership.

The reason to auto-take on iPad is product semantics: the regular-width layout
has a desktop-like sidebar/detail model, and tapping a row is an intentional
"make this active" action. On the phone, navigation is more transient and should
not silently steal ownership.

### 2. Ctrl+Tab worktree navigation on iPad

iPad hardware-keyboard navigation shall mirror the Mac `next_tab` /
`previous_tab` behavior exactly:

1. `next_tab` selects the next attention-carrying selectable worktree in cyclic
   sidebar order, excluding the current worktree.
2. If no other selectable worktree has attention, `next_tab` selects the next
   selectable worktree in cyclic sidebar order.
3. `previous_tab` applies the same rule in reverse.
4. With no current selection, forward starts from before the first worktree and
   reverse starts from after the last worktree.
5. Zero or one selectable worktree is a no-op.

After the target worktree is selected, iPad applies the active-selection behavior
from section 1: focus the terminal and take ownership. This keeps the shortcut's
meaning consistent across Mac and iPad while preserving the iPad-specific
active-device behavior after selection. Attention acknowledgement should follow
the same arrival semantics as Mac: the selected worktree is acknowledged through
the normal selection path rather than through shortcut-specific state changes.

### 3. Four-direction Add Pane affordance

The iPad detail toolbar shall expose pane creation for the focused pane with four
explicit directions:

- Split Right
- Split Down
- Split Left
- Split Up

The currently focused pane is the implicit target. The server remains the source
of truth for pane lifecycle: after sending a split request, the UI waits for the
next pane snapshot to reflect the resulting split tree rather than mutating the
local tree optimistically.

The four directions are semantic, not just labels over two split axes:
Right/Down insert the new pane after the focused pane along the horizontal or
vertical axis; Left/Up insert before it along that axis. If the current
pane-control protocol only exposes right/down-style insertion, this spec extends
that protocol and the host-side mutator to represent before/after placement
explicitly rather than faking Left/Up in the client.

The affordance should be disabled or hidden when no host, worktree, or focused
pane is selected. Conflict responses from the server should not show noisy
errors if a subsequent pane snapshot will describe the actual state.

### 4. Trackpad scrolling over the terminal

On iPad with a hardware keyboard and trackpad, indirect pointer scroll gestures
over the terminal shall route through the terminal's normal scroll/input path.
Mouse-reporting applications such as `vim`, `less`, and `tmux` should receive
scroll input when they have captured mouse reporting. Otherwise, the gesture
scrolls terminal scrollback.

The fallback must not interfere with the existing touch selection gestures. Touch
drag and long-press selection remain governed by the current touch recognizers;
trackpad scroll is the added path.

### 5. Add Worktree default action on mobile

On iPad and iOS, while the Add Worktree sheet is presented and the form is valid,
pressing Return on a hardware keyboard shall submit the Create action. While the
form is invalid or already submitting, Return shall not submit.

This preserves Mac behavior, where the native Add Worktree sheet already marks
Create as the default action, and brings mobile hardware-keyboard behavior in
line with the same expectation.

### 6. Sidebar density and background model

The terminal theme background color shall fill the entire iPad screen, including
the area behind the sidebar. The sidebar shall be rendered as a themed overlay on
top of that background, matching the Mac relationship between terminal surface
and sidebar. Terminal text or canvas content shall not render behind the sidebar;
only the background color extends underneath it.

The iPad sidebar row trailing padding shall be tightened so git divergence stats
sit close to the sidebar's trailing edge. The goal is density and scanability,
not decorative whitespace. The change should preserve enough hit target area for
row selection and swipe actions.

## Data Flow

### Sidebar tap

`WorktreeListContent` sends a worktree or leaf selection callback to
`IPadRootLayout`. `IPadRootLayout` updates `IPadAppState`, increments or updates
a focus request token for the detail `SingleSessionView`, and signals that the
new pane should take display ownership. `SingleSessionView` passes the focus
token to `TerminalPaneView`, which calls into UIKit to focus the terminal input
container.

### Ctrl+Tab

The iPad hardware-keyboard command resolves to the same attention-first worktree
selection rule used by Mac. Once a target worktree is found, the iPad selection
path is reused rather than creating a shortcut-specific focus path.

### Split pane

The user taps a split-direction toolbar control in the iPad detail column. The
focused pane session name and requested direction are sent through the existing
pane-control path. The host mutates the authoritative split tree. The mobile
client refreshes or receives the next pane snapshot and updates the detail and
sidebar from that snapshot.

## Error Handling

- Selecting an in-flight worktree remains a no-op.
- Selecting a worktree with no pane layout selects the worktree but cannot focus
  or take ownership of a pane.
- If display ownership cannot be taken because the session is no longer live,
  the terminal view should remain in its existing reconnect/ended state rather
  than showing a new ownership-specific error.
- Split commands with no focused pane are disabled before the user can invoke
  them.
- Split conflicts rely on the next authoritative pane snapshot instead of noisy
  transient errors.
- Add Worktree Return handling follows the same disabled state as the Create
  button.

## Testing

### Pure selection and state tests

- iPad selection helpers update `selectedWorktreePath`, `focusedPaneId`, and the
  focus/ownership request token for worktree-row taps.
- Pane-row taps update the focused pane and request focus/ownership.
- In-flight worktree rows remain no-ops.
- iPad Ctrl+Tab uses the same attention-first target selection as Mac and then
  runs the iPad active-selection behavior.

### View construction and command tests

- `SingleSessionView` receives a changing focus request token when iPad
  selection changes.
- Add Worktree mobile view exposes default submit behavior only when `canSubmit`
  is true and `isSubmitting` is false.
- Detail toolbar exposes Split Right/Down/Left/Up only when a focused pane is
  available.

### Terminal input tests

- Trackpad/indirect scroll gestures invoke the terminal scroll/input path.
- Touch selection recognizers still support long-press select, select all, copy,
  cancel, and paste behaviors.

### Visual and layout checks

- Sidebar row trailing insets keep divergence stats near the trailing edge.
- The iPad layout paints the terminal background color behind the sidebar, while
  terminal content stays bounded to the detail column.

## Out of Scope

- Mobile port chips and the Graftty proxy for local dev-server ports.
- Changing iPhone ownership semantics.
- Rendering terminal text or canvas under the iPad sidebar.
- Replacing the existing Mac Ctrl+Tab behavior.
- Optimistic local split-tree mutation on mobile.
