# Single-Responder Keyboard Input Design

**Date:** 2026-07-10
**Status:** Approved for written-spec review

## Problem

GrafttyMobile currently makes `TerminalSoftwareKeyboardProxyView` the iOS
first responder so committed software-keyboard text can bypass
`ghostty_surface_text`. It then prevents libghostty-spm's `UITerminalView` from
becoming first responder with Objective-C method replacement.

That split fixes software text but removes Ghostty's hardware-key pipeline from
the responder path. The proxy implements text insertion and delete only, so
non-text physical keys are lost. Escape was recently restored with a dedicated
`pressesBegan` case, but hardware arrows still fail and the same defect applies
to Home, End, Page Up/Down, modified arrows, function keys, and future terminal
keyboard protocols.

The command model also assigns Ghostty `next_tab` and `previous_tab` to Graftty
worktree navigation. Graftty has no independent Ghostty-tab object; panes are
the local terminal collection within a worktree. Cross-worktree navigation is
a Graftty application concern and should not consume Ghostty's tab actions.

## Decision

Restore libghostty-spm's `UITerminalView` as the sole iOS keyboard first
responder. Add supported extension points to the libghostty-spm fork for
Graftty's software-input and ownership requirements. Remove the Graftty
keyboard proxy, runtime responder method replacement, and key-specific Escape
patch.

Use these navigation semantics on both Mac and iPad:

- Ghostty `next_tab`, including `Ctrl+Tab`, cycles forward through panes in the
  current worktree.
- Ghostty `previous_tab`, including `Ctrl+Shift+Tab`, cycles backward through
  panes in the current worktree.
- Graftty-owned `Ctrl+Option+Tab` navigates to the next worktree using the
  existing attention-first rule.
- Graftty-owned `Ctrl+Option+Shift+Tab` navigates to the previous worktree using
  the same rule in reverse.

## Goals

- Restore Ghostty's complete hardware-key translation on iPad, including
  Escape and arrow keys, without enumerating terminal keys in Graftty.
- Preserve raw software-keyboard text, Return-to-CR, and delete-to-DEL routing
  through `SessionClient`.
- Preserve marked-text/IME composition.
- Keep libghostty's accessory row hidden while using supported fork API rather
  than Objective-C runtime mutation.
- Prevent followers and ownerless sessions from acquiring keyboard input.
- Preserve app-command precedence for enabled pane and worktree commands.
- Make pane/worktree navigation semantics consistent on Mac and iPad.

## Non-Goals

- Reimplementing Ghostty HID, modifier, Kitty keyboard, or terminal escape
  sequence translation in Graftty.
- Making Graftty's fixed worktree shortcuts configurable through Ghostty.
- Changing render-throttle behavior introduced by the concurrent iPad battery
  work.
- Changing the existing attention-first worktree ordering algorithm.
- Guaranteeing that every system-reserved iPadOS shortcut can be overridden;
  final physical-device smoke testing remains required.

## Architecture

### 1. libghostty-spm UIKit Extension Points

The fork will expose a main-actor software-input delegate:

```swift
@MainActor
public protocol TerminalSoftwareInputDelegate: AnyObject {
    func terminalView(_ view: UITerminalView, insertText text: String) -> Bool
    func terminalViewDeleteBackward(_ view: UITerminalView) -> Bool
}
```

`UITerminalView` will expose:

```swift
public weak var softwareInputDelegate: (any TerminalSoftwareInputDelegate)?
public var isKeyboardInputEnabled: Bool
public var showsInputAccessory: Bool
```

The delegate methods return `true` when the embedder handled the committed
operation. A missing delegate or `false` result preserves libghostty-spm's
existing behavior, so other embedders do not change.

Committed text will pass through one internal commit function used by direct
software input and marked-text/IME completion. `UITerminalView.insertText(_:)`
must retain its existing `hardwareKeyHandled` suppression guard before calling
that function. Only after the guard has determined that the text did not come
from an already-routed physical key may the commit function ask the delegate
before calling `surface.sendText`. Preedit state and UIKit text-input delegate
notifications remain owned by libghostty-spm.

`UITerminalView.deleteBackward()` must keep this exact ordering: edit marked
text locally first, suppress a callback whose physical Backspace was already
handled by the hardware path second, ask the software-input delegate third,
and use Ghostty's normal delete behavior last. The delegate is therefore a
software/IME commit hook, not a second route for physical keys.

This extension does not broaden `shouldSuppressUIKeyInput`. Control-, Option-,
and Command-modified printable keys and dead-key composition retain the fork's
existing UIKit arbitration. If those paths produce a later committed-text
callback, delegation replaces the existing `surface.sendText` sink for that
callback; it does not create another callback or suppress the preceding
physical event. Regression tests must compare delegate-disabled and
delegate-enabled event sequences for modified printable and dead-key input,
with only the committed-text sink changing.

`isKeyboardInputEnabled` controls `canBecomeFirstResponder`. Turning it off
while the view is first responder resigns it. `showsInputAccessory` controls
`inputAccessoryView`; it defaults to `true` for compatibility.

The existing `UITerminalView.pressesBegan`, `pressesEnded`, and cancellation
handlers remain unchanged. They continue routing `UIKey` values through
`TerminalHardwareKeyRouter`, including direct input for the in-memory backend.

### 2. Graftty Terminal Container

`TerminalInputContainerView` will implement `TerminalSoftwareInputDelegate`.
It retains Graftty closures for committed text and delete, and returns whether
those closures are installed.

The container will:

- set `terminalView.softwareInputDelegate = self`;
- set `terminalView.showsInputAccessory = false`;
- set `terminalView.isKeyboardInputEnabled` from owner eligibility;
- focus `terminalView` directly for tap and external focus requests; and
- resign it when eligibility is removed.

`TerminalSoftwareKeyboardProxyView` and its full-screen transparent overlay are
deleted. The `UITerminalView` remains the touch target, so pan, pinch, pointer
scroll, selection, and built-in keyboard handling share one view.

The `UITerminalView` input delegate calls:

- `SessionClient.sendSoftwareKeyboardText(_:)` for committed software text;
- `SessionClient.deleteBackward()` for software delete.

Physical keys covered by libghostty-spm's `hardwareKeyHandled` classification
never reach these delegate methods because suppression runs before delegation.
Modified printable and dead-key paths keep libghostty-spm's existing combined
physical-event/composition behavior; the delegate only replaces a subsequent
committed-text sink if UIKit produces one.

### 3. App Commands in the Responder Chain

`TerminalInputContainerView`, the superview immediately after
`UITerminalView` in the responder chain, will publish enabled application
`UIKeyCommand` values. It retains the current behavior for:

- stable command signatures and menu rebuild requests;
- `wantsPriorityOverSystemBehavior = true`;
- exact normalized chord matching;
- stale cached-command rejection with `canPerformAction`; and
- exact enablement checks for non-navigation commands.

This moves app-command publication from the deleted proxy without changing the
semantic command candidates. An enabled app command wins; every other hardware
key remains owned by `UITerminalView` and Ghostty. Every emitted pane-tab chord
and the two fixed worktree chords described below are deliberately retained
when they would no-op. All other disabled commands continue to be omitted.

The test harness must place the terminal and container in a `UIWindow`, make
the terminal first responder, and verify that the container is reachable as
the next command responder. Direct computed-property tests alone are not
sufficient.

### 4. Pane Navigation

`GhosttyCommandRegistry` will map `.nextTab` and `.previousTab` to
`.focusPaneByOrder` instead of `.navigateWorktree`.

On iPad, the existing command context will therefore route host-resolved or
default Ghostty tab chords through `PaneLayoutNavigation.nextInOrder`. Every
emitted chord for either tab action, including a custom host chord, stays
registered when there is zero or one pane and invokes a consumed no-op rather
than falling through to Ghostty or the system as the pane count changes.

On Mac, `next_tab` and `previous_tab` will be registered with the pane-focus
command group and use the same stable pane-order focus path. They will no
longer be supplied to the worktree-navigation command view.

`GhosttyKeybindBridge` currently exposes only one chord per action, so it
cannot by itself guarantee Ghostty's default `Ctrl+Tab` alias when a host
configuration supplies another `next_tab` chord. Graftty will therefore own
fixed, Ghostty-compatible pane aliases for `Ctrl+Tab` and
`Ctrl+Shift+Tab` on both platforms. A host-resolved `next_tab` or
`previous_tab` chord remains an additional pane shortcut when it does not
collide with a fixed alias. The command registry labels for those actions
change from worktree to pane terminology.

### 5. Fixed Graftty Navigation

`GrafttyProtocol` will define all shared fixed navigation chords:

```swift
public enum GrafttyNavigationShortcuts {
    public static let nextPane = ShortcutChord(
        key: "tab",
        modifiers: [.control]
    )
    public static let previousPane = ShortcutChord(
        key: "tab",
        modifiers: [.control, .shift]
    )
    public static let nextWorktree = ShortcutChord(
        key: "tab",
        modifiers: [.control, .option]
    )
    public static let previousWorktree = ShortcutChord(
        key: "tab",
        modifiers: [.control, .option, .shift]
    )
}
```

These are application shortcuts, not host-configurable `GhosttyAction`
bindings. Reserving the pane aliases is a deliberate product decision: a host
may add or remap its own tab-action chord, but it cannot unbind Graftty's
cross-platform `Ctrl+Tab` pane behavior.

Mac will use the shared chords in its focused worktree-navigation command
buttons and add the fixed pane aliases beside the host-resolved pane commands.
iPad will add all four fixed candidates to both its SwiftUI scene commands and
terminal-container `UIKeyCommand` list.

Both platforms use the same collision precedence:

1. fixed Graftty worktree shortcuts;
2. fixed Graftty pane aliases; and
3. host-resolved Ghostty chords.

iPad applies this order while deduplicating command candidates and omits a
colliding host candidate. Mac must perform the equivalent filtering before
attaching `.keyboardShortcut` to a host-resolved command; its menu action may
remain available without a keyboard shortcut. This rule applies even when the
fixed command currently has no target. The design does not add a new
unshortcutted iPad command surface.

All four fixed navigation commands stay registered and consume their chords
while terminal/worktree command context exists. With zero or one eligible
pane/worktree their handlers no-op. This stable reservation avoids making a
collision dependent on transient pane or worktree count.

## Data Flow

### Software Keyboard

1. `UITerminalView` owns first responder and UIKit text composition.
2. UIKit commits text through libghostty-spm's text-input handler.
3. The handler asks `TerminalSoftwareInputDelegate` to handle the committed
   text.
4. `TerminalInputContainerView` forwards it to `SessionClient`.
5. `SessionClient` applies Return-to-CR and raw UTF-8 rules and sends the PTY
   bytes.

### Hardware Keyboard

1. UIKit checks priority application `UIKeyCommand` values in the responder
   chain.
2. An enabled Graftty app chord invokes its semantic pane/worktree command.
3. Any other key reaches `UITerminalView.pressesBegan`.
4. libghostty-spm translates the physical `UIKey`, modifiers, press/repeat
   phase, and backend route.
5. The in-memory session sends the resulting bytes through `SessionClient`'s
   existing outbound pipe.

## Ownership and Focus

- Owners install software-input handlers and set keyboard input enabled.
- Followers and ownerless sessions leave keyboard input disabled but retain
  terminal gestures and pointer scrolling.
- Owner promotion triggers the existing focus-request counter and focuses
  `UITerminalView`.
- Owner loss resigns `UITerminalView` if necessary.
- Hiding the software keyboard resigns the terminal. Scene-level app commands
  remain available where iPadOS permits them.

## Error Handling

- A missing Graftty software-input handler falls back to libghostty-spm's
  default input behavior.
- An action whose chord is missing or untranslatable is omitted.
- Disabled split, close, and directional-focus commands are omitted. Every
  emitted pane-tab chord and both fixed worktree chords are the exception:
  they stay registered and consume as no-ops when there is no alternate target.
- A stale cached command fails exact current-table validation and continues up
  the responder chain.
- A failed host keybinding fetch retains bundled Ghostty defaults, including
  `Ctrl+Tab` and `Ctrl+Shift+Tab` for pane navigation.

## Testing

### libghostty-spm Fork

- Default delegate/accessory/keyboard settings preserve existing behavior.
- A hardware printable key produces exactly one outbound write through the
  hardware router and never invokes the software-input delegate.
- A hardware Backspace produces exactly one outbound write through the
  hardware router and never invokes the software-input delegate.
- Modified printable and dead-key input produce the same physical-event and
  composition-callback sequence with or without a delegate; enabling the
  delegate changes only the sink for any committed-text callback.
- Direct software-keyboard text invokes a handling delegate exactly once and
  suppresses `surface.sendText`.
- An IME commit invokes a handling delegate exactly once, preserves preedit
  notifications, and suppresses `surface.sendText`.
- Delegate-handled software delete suppresses default delete only outside
  marked text.
- Disabling keyboard input changes responder eligibility and resigns an active
  responder.
- Hiding the accessory returns nil without affecting hardware press handling.
- Existing hardware router tests cover Escape, arrows, navigation keys,
  modifiers, and the in-memory direct-input backend.

### GrafttyMobileKit

- `UITerminalView`, not a proxy, becomes first responder for an owner.
- The container is the next responder and publishes priority app commands.
- Committed software text and delete reach `SessionClient` once.
- A follower cannot acquire keyboard focus.
- App-command changes rebuild and validate the container command table.
- No proxy overlay or Objective-C method replacement remains.
- Escape and arrow behavior is covered by fork routing tests plus a physical
  iPad smoke test; Graftty does not add per-key byte mappings.

### Navigation

- `next_tab` and `previous_tab` map to pane order on both platforms.
- `Ctrl+Tab` and `Ctrl+Shift+Tab` remain fixed pane aliases even when a host
  remaps or removes its own tab action chord.
- Pane cycling wraps and consumes as a no-op for one pane.
- `Ctrl+Option+Tab` and its shifted reverse use attention-first worktree order.
- Fixed worktree shortcuts are identical on Mac and iPad.
- Fixed worktree and pane shortcuts are reserved on both platforms, including
  no-op states. A colliding host Ghostty candidate is omitted on iPad and
  receives no keyboard shortcut on Mac, where its menu action may remain.

## Migration and Supersession

This design supersedes the responder ownership and proxy implementation in
`2026-07-09-ipad-hardware-shortcut-responder-design.md`, the relevant input and
navigation portions of the 2026-07-07/08 Ghostty keyboard-command specs and
plans, and Task 5's Escape-only proxy patch in
`2026-07-10-ipad-render-throttle.md`.

The render-pace governor, libghostty render throttle, touch promotion, and
their tests remain in force. Fork work starts from the currently pinned
`TerminalRenderPace` revision introduced by commit `02714134`; the dependency
pin advances only after the new delegate APIs land. The migration must preserve
`renderPace`, `onUserInteraction`, selection, paste, and container-capture
behavior. The already-landed Escape-only proxy code will be removed as part of
the single-responder migration.

The affected EARS requirements and generated spec tests must be migrated in
the same change as the implementation. The input requirements are `IOS-6.2`,
`IOS-6.6` through `IOS-6.8`, `IOS-6.14`, `IOS-6.16` through `IOS-6.18`, and
`IOS-11.12`. The command requirements are `KBD-5.1` through `KBD-5.6`,
`IPAD-8.1` through `IPAD-8.7`, `IPAD-9.2`, `IPAD-9.3`, `IPAD-9.5`,
`IPAD-9.6`, `IPAD-9.9`, and `IPAD-9.10`. Replacements will describe supported
single-responder behavior, retain attention-first worktree navigation under
the fixed Option chords, reserve all four navigation aliases, and define
Ghostty tab actions as pane navigation.

## Success Criteria

- On a physical iPad keyboard, Escape, all four arrows, modified arrows, and
  normal text reach the terminal correctly.
- `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle panes in the current worktree on Mac and
  iPad.
- `Ctrl+Option+Tab` / `Ctrl+Option+Shift+Tab` navigate worktrees on Mac and
  iPad.
- Software Return, delete, paste, and IME input retain current behavior.
- Non-owners cannot type but can still scroll, pinch, select, and interact with
  terminal content.
- No Graftty keyboard proxy, responder method swizzle, or per-terminal-key
  passthrough table remains.
