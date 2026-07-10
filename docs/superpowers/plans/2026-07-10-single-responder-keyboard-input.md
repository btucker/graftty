# Single-Responder Keyboard Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore complete iPad hardware-key delivery, keep raw software-keyboard input, and make pane/worktree navigation shortcuts deterministic on Mac and iPad.

**Architecture:** `UITerminalView` becomes the only iOS keyboard first responder and retains all physical-key translation. A small supported libghostty-spm delegate intercepts committed software text/delete at the existing UIKit commit boundary, while Graftty's container remains the next responder for application commands. Shared fixed navigation chords and an explicit semantic command model keep pane cycling separate from attention-first worktree navigation on both platforms.

**Tech Stack:** Swift 6, SwiftUI, UIKit responder chain and `UIKeyCommand`, libghostty-spm fork, Swift Testing, Swift Package Manager, Xcode iOS simulator tests, `scripts/generate-specs.py`.

**Design spec:** `docs/superpowers/specs/2026-07-10-single-responder-keyboard-input-design.md`

---

## Global Constraints

- Graftty worktree: `/Users/btucker/projects/graftty/.worktrees/ipad-improvements`, branch `ipad-improvements`.
- Fork checkout: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm`, branch `expose-selection-api`.
- Start fork work at `1d9f6698898d9865e416afe214c05b1eb27d11c3`, which already contains `TerminalRenderPace`.
- Never edit `.build/checkouts/libghostty-spm`; it is generated and detached.
- Do not use `git add -A` or `git add .`. Stage the exact task files only.
- Follow TDD for every behavior change: add a focused test, run it and record the expected failure, implement the minimum change, rerun focused tests, then commit.
- macOS `swift test` does not compile `#if canImport(UIKit)` code. Every mobile task requires an iOS Simulator `xcodebuild test` run.
- Do not hand-edit `SPECS.md`. Change `@spec` sources, then run `python3 scripts/generate-specs.py`.
- Preserve `renderPace`, `onUserInteraction`, selection, paste/refocus, indirect scrolling, and `captureContainer` behavior throughout the responder migration.
- Fixed navigation chords remain registered while the main terminal/worktree command context is focused, including zero/one-target states. Their handlers consume and no-op; they do not fall through.

## File Structure

| File | Responsibility | Planned change |
|---|---|---|
| Fork `Sources/GhosttyTerminal/Platform/UIKit/TerminalSoftwareInputDelegate.swift` | Embedder software-commit contract | New public delegate protocol. |
| Fork `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift` | UIKit terminal responder state | Add delegate, keyboard eligibility, and accessory visibility state. |
| Fork `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+UITextInput.swift` | UIKit text/delete entry point | Preserve suppression/marked-text ordering before delegation. |
| Fork `Sources/GhosttyTerminal/Platform/UIKit/TerminalTextInputHandler@UIKit.swift` | Direct and IME commit boundary | Route committed text through one delegate-or-surface sink. |
| Fork `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+InputAccessory.swift` | Built-in accessory | Honor `showsInputAccessory`. |
| Fork `Tests/GhosttyKitTest/UITerminalViewSoftwareInputTests.swift` | Fork UIKit behavior | Cover defaults, delegation, suppression, IME, focus, and accessory behavior. |
| `Package.resolved` | Fork pin | Advance to the pushed delegate API revision. |
| `Sources/GrafttyProtocol/Keybinds/GrafttyNavigationShortcuts.swift` | UI-free fixed chord definitions | Define four fixed Graftty navigation chords and precedence. |
| `Sources/GrafttyProtocol/Keybinds/GhosttyCommandRegistry.swift` | Ghostty action semantics | Map tab actions to panes and relabel/regroup them. |
| `Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift` | iPad scene/responder command table | Use explicit semantic candidates, stable no-op reservation, and collision precedence. |
| `Sources/GrafttyMobileKit/App/IPadRootLayout.swift` | iPad command execution | Route Ghostty tabs to panes and fixed Option chords to worktrees. |
| `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` | Terminal container/responder bridge | Delete proxy/swizzle and move software delegate/app commands onto the container. |
| `Sources/GrafttyMobileKit/App/RootView.swift` | Owner-aware input wiring | Install text/delete handlers and keyboard eligibility without Escape special casing. |
| `Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift` | Mobile app startup | Remove Objective-C responder mutation. |
| `Sources/Graftty/Views/WorktreeNavFocusedValues.swift` | Mac worktree command buttons | Use fixed Option chords and stable no-op reservation. |
| `Sources/Graftty/GrafttyApp.swift` | Mac pane/menu commands | Add fixed pane aliases, route tabs to panes, and filter collisions. |
| `Tests/...` and `SPECS.md` | Behavioral contract | Replace proxy/worktree-tab requirements and regenerate inventory. |

### Task 1: Add Supported UIKit Input Extension Points to libghostty-spm

**Files:**
- Create: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/TerminalSoftwareInputDelegate.swift`
- Modify: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift`
- Modify: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+UITextInput.swift`
- Modify: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/TerminalTextInputHandler@UIKit.swift`
- Modify: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+InputAccessory.swift`
- Test: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Tests/GhosttyKitTest/UITerminalViewSoftwareInputTests.swift`
- Test: `/Users/btucker/projects/graftty-libghostty-fork/libghostty-spm/Tests/GhosttyKitTest/TerminalHardwareKeyRouterTests.swift`

- [ ] **Step 1: Verify the fork baseline**

Run:

```bash
git -C /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm status -sb
git -C /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm rev-parse HEAD
```

Expected: clean `expose-selection-api` at `1d9f6698898d9865e416afe214c05b1eb27d11c3`.

- [ ] **Step 2: Write failing UIKit delegate tests**

Add tests under `#if canImport(UIKit)` for this public contract:

```swift
@MainActor
public protocol TerminalSoftwareInputDelegate: AnyObject {
    func terminalView(_ view: UITerminalView, insertText text: String) -> Bool
    func terminalViewDeleteBackward(_ view: UITerminalView) -> Bool
}
```

Cover:

- defaults: delegate nil, keyboard enabled, accessory shown;
- handled direct committed text calls the delegate once;
- delegate `false` preserves `surface.sendText` fallback;
- IME/unmark commit uses the same delegate sink and preserves preedit notifications;
- marked-text delete happens before delegate delete;
- a set `hardwareKeyHandled` suppresses printable and Backspace callbacks before delegation;
- delegate-on/off modified printable and dead-key seams preserve the same event sequence, changing only the committed-text sink;
- disabling keyboard input changes `canBecomeFirstResponder` and resigns an active responder;
- hiding the accessory returns nil without changing hardware routing.

If `UIKey`/`UIPress` construction blocks modified/dead-key coverage, add the smallest internal arbitration test seam. Do not change `UITerminalView+Keyboard.swift` behavior to make it testable.

- [ ] **Step 3: Run the tests and verify RED**

Run from the fork:

```bash
xcodebuild test -scheme GhosttyKit-Package -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.5' IPHONEOS_DEPLOYMENT_TARGET=17.0 -only-testing:GhosttyKitTest/UITerminalViewSoftwareInputTests
```

Expected: compile failure because the delegate and properties do not exist. If the package scheme name differs, use `xcodebuild -list` and record the actual scheme before continuing.

- [ ] **Step 4: Implement the delegate and state API**

Add to `UITerminalView`:

```swift
public weak var softwareInputDelegate: (any TerminalSoftwareInputDelegate)?
public var isKeyboardInputEnabled = true {
    didSet {
        if !isKeyboardInputEnabled, isFirstResponder { resignFirstResponder() }
    }
}
public var showsInputAccessory = true

override public var canBecomeFirstResponder: Bool { isKeyboardInputEnabled }
```

Call `reloadInputViews()` when accessory visibility changes on an active
responder. Return `terminalInputAccessory` only when `showsInputAccessory` is
true; expose the property on all UIKit builds while keeping the toolbar effect
non-Catalyst.

- [ ] **Step 5: Implement one committed-text sink with exact ordering**

Keep `UITerminalView.insertText(_:)`'s `hardwareKeyHandled` guard first. Keep `deleteBackwardInMarkedText()` first and the hardware suppression guard second. Only then call the delegate; fall back to existing behavior when it returns false.

Centralize direct, `replace(_:withText:)`, sticky fallback, and IME/unmark
committed text in `TerminalTextInputHandler`:

```swift
private func commitText(_ text: String, in view: UITerminalView) {
    guard view.softwareInputDelegate?.terminalView(view, insertText: text) != true else { return }
    view.surface?.sendText(text)
}
```

Preserve sticky-modifier paths, preedit clearing, accessory refresh, and `UITextInputDelegate` notifications. The hook replaces an existing commit sink; it must not create or suppress modified/dead-key callbacks.

- [ ] **Step 6: Run fork tests and builds GREEN**

```bash
xcodebuild test -scheme GhosttyKit-Package -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.5' IPHONEOS_DEPLOYMENT_TARGET=17.0 -only-testing:GhosttyKitTest/UITerminalViewSoftwareInputTests -only-testing:GhosttyKitTest/TerminalHardwareKeyRouterTests
swift test
xcodebuild build -scheme GhosttyTerminal -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation
./Script/test.sh
```

Expected: focused UIKit tests pass, macOS package tests pass, iOS build succeeds.

- [ ] **Step 7: Commit and push the fork**

```bash
git -C /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm add \
  Sources/GhosttyTerminal/Platform/UIKit/TerminalSoftwareInputDelegate.swift \
  Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift \
  Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+UITextInput.swift \
  Sources/GhosttyTerminal/Platform/UIKit/TerminalTextInputHandler@UIKit.swift \
  Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+InputAccessory.swift \
  Tests/GhosttyKitTest/UITerminalViewSoftwareInputTests.swift \
  Tests/GhosttyKitTest/TerminalHardwareKeyRouterTests.swift
git -C /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm commit -m "Add supported UIKit software input hooks"
git -C /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm push origin expose-selection-api
git -C /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm rev-parse HEAD
```

Record the pushed SHA for Task 2.

### Task 2: Advance Graftty to the Fork API

**Files:**
- Modify: `Package.resolved`

- [ ] **Step 1: Update only libghostty-spm**

```bash
swift package update libghostty-spm
git diff -- Package.resolved
```

Expected: the libghostty revision changes from `1d9f669...` to Task 1's pushed SHA.

- [ ] **Step 2: Verify both platform builds**

```bash
swift build
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-single-responder-dd -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: both builds succeed with the new public API visible.

- [ ] **Step 3: Commit the pin only**

```bash
git add Package.resolved
git commit -m "chore: bump libghostty-spm for UIKit input hooks"
```

### Task 3: Define Shared Navigation Chords and Ghostty Pane Semantics

**Files:**
- Create: `Sources/GrafttyProtocol/Keybinds/GrafttyNavigationShortcuts.swift`
- Modify: `Sources/GrafttyProtocol/Keybinds/GhosttyCommandRegistry.swift`
- Modify: `Sources/GrafttyProtocol/Keybinds/GhosttyDefaultKeybinds.swift`
- Create: `Tests/GrafttyProtocolTests/Keybinds/GrafttyNavigationShortcutsTests.swift`
- Modify: `Tests/GrafttyProtocolTests/Keybinds/GhosttyCommandRegistryTests.swift`
- Modify: `Tests/GrafttyProtocolTests/Keybinds/GhosttyDefaultKeybindsTests.swift`

- [ ] **Step 1: Write failing shared-semantic tests**

Assert exact fixed chords:

```swift
#expect(GrafttyNavigationShortcuts.nextPane == ShortcutChord(key: "tab", modifiers: [.control]))
#expect(GrafttyNavigationShortcuts.previousPane == ShortcutChord(key: "tab", modifiers: [.control, .shift]))
#expect(GrafttyNavigationShortcuts.nextWorktree == ShortcutChord(key: "tab", modifiers: [.control, .option]))
#expect(GrafttyNavigationShortcuts.previousWorktree == ShortcutChord(key: "tab", modifiers: [.control, .option, .shift]))
```

Also assert precedence is worktree fixed, pane fixed, then host; `.nextTab`/`.previousTab` have `Next Pane`/`Previous Pane` labels, map to `.focusPaneByOrder`, appear in `macPaneFocusActions`, and no longer appear in a worktree action group.

- [ ] **Step 2: Run and verify RED**

```bash
swift test --filter GrafttyNavigationShortcutsTests
swift test --filter GhosttyCommandRegistryTests
```

Expected: missing fixed-shortcut type and old worktree mappings fail.

- [ ] **Step 3: Implement the fixed definitions and registry remap**

Create `GrafttyNavigationShortcuts` as UI-free `ShortcutChord` constants. Move `.nextTab` and `.previousTab` into `macPaneFocusActions`, map them to pane order, and remove the obsolete `.navigateWorktree` enum case if no remaining call site requires it. Keep bundled Command-bracket defaults as host/default tab-action chords; fixed Control-Tab aliases are no longer conditional on bundled fallback provenance.

- [ ] **Step 4: Run and verify GREEN**

```bash
swift test --filter GrafttyNavigationShortcutsTests
swift test --filter GhosttyCommandRegistryTests
swift test --filter GhosttyDefaultKeybindsTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyProtocol/Keybinds/GrafttyNavigationShortcuts.swift Sources/GrafttyProtocol/Keybinds/GhosttyCommandRegistry.swift Sources/GrafttyProtocol/Keybinds/GhosttyDefaultKeybinds.swift Tests/GrafttyProtocolTests/Keybinds/GrafttyNavigationShortcutsTests.swift Tests/GrafttyProtocolTests/Keybinds/GhosttyCommandRegistryTests.swift Tests/GrafttyProtocolTests/Keybinds/GhosttyDefaultKeybindsTests.swift
git commit -m "feat: separate pane and worktree navigation shortcuts"
```

### Task 4: Rebuild iPad Navigation Candidates Around Explicit Semantics

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift`
- Modify: `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`
- Test: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`
- Test: `Tests/GrafttyMobileKitTests/UI/IPadWorktreeNavigationTests.swift`

- [ ] **Step 1: Write failing candidate and routing tests**

Cover both scene and responder projections:

- fixed pane candidates exist under loading, host-resolved, and fallback keybinding provenance;
- fixed worktree candidates are Graftty semantic commands, not fake `GhosttyAction.nextTab` values;
- host-resolved tab chords are additional pane commands;
- every emitted tab chord and both fixed worktree chords remain present when execution would no-op;
- dedup precedence is fixed worktree, fixed pane, then host;
- a colliding host candidate is omitted on iPad;
- `.nextTab`/`.previousTab` execute `PaneLayoutNavigation.nextInOrder`;
- fixed Option chords execute existing `IPadWorktreeNavigation.nextPath` attention-first behavior.

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-single-responder-dd -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests -only-testing:GrafttyMobileKitTests/IPadWorktreeNavigationTests
```

Expected: old candidate filtering drops no-op commands and routes tab actions to worktrees.

- [ ] **Step 3: Introduce an explicit mobile command semantic**

Replace the action-only candidate with an internal semantic such as:

```swift
enum MobileAppCommand {
    case ghostty(GhosttyAction)
    case navigateWorktree(forward: Bool)
}
```

Descriptors carry the semantic, label, chord, and closure. Build fixed worktree candidates first, fixed pane aliases second, and host Ghostty candidates third. Deduplicate on normalized input plus modifiers. Scene buttons and container `UIKeyCommand` descriptors must project from this single candidate table.

- [ ] **Step 4: Separate reservation from execution enablement**

Do not use `isEnabled` to omit tab or fixed worktree navigation candidates. Their execution closures validate current layout/list state and no-op. Continue omitting disabled split, close, and directional-focus actions.

- [ ] **Step 5: Run focused tests GREEN**

Run the Step 2 command again. Expected: all routing, stable reservation, and collision tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift Sources/GrafttyMobileKit/App/IPadRootLayout.swift Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift Tests/GrafttyMobileKitTests/UI/IPadWorktreeNavigationTests.swift
git commit -m "feat(ipad): separate pane and worktree keyboard navigation"
```

### Task 5: Restore UITerminalView as the Sole iOS Input Responder

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`
- Modify: `Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift`
- Test: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`
- Test: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`
- Regression: `Tests/GrafttyMobileKitTests/Session/SessionClientTests.swift`

- [ ] **Step 1: Rewrite responder tests first**

Replace proxy/swizzle/Escape tests with tests that prove:

- owner input enables `UITerminalView.canBecomeFirstResponder` and non-owner input disables it;
- `showsInputAccessory == false` gives no libghostty accessory;
- `TerminalInputContainerView` conforms to `TerminalSoftwareInputDelegate` and forwards committed text/delete once;
- a `UIWindow` containing the container can make `terminalView` first responder and `terminalView.next === container`;
- container `keyCommands` retain priority, signatures, rebuild counting, normalized dispatch, and stale-command rejection;
- focus requests remain pending until the terminal is eligible;
- paste refocuses the eligible terminal;
- hit testing reaches `UITerminalView`, and pan/pinch/selection/pointer-scroll behavior remains intact;
- no Escape-specific handler or proxy type remains.

- [ ] **Step 2: Run and verify RED**

```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-single-responder-dd -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:GrafttyMobileKitTests/TerminalPaneViewTests
```

Expected: new first-responder and delegate assertions fail against the proxy architecture.

- [ ] **Step 3: Move software input and app commands to the container**

Make `TerminalInputContainerView` implement `TerminalSoftwareInputDelegate`. Store text/delete closures on the container, set `terminalView.softwareInputDelegate = self`, set `terminalView.showsInputAccessory = false`, and drive `terminalView.isKeyboardInputEnabled` from owner eligibility.

Move the proxy's `HardwareKeyboardCommandSignature`, `keyCommands`, `canPerformAction`, exact matching, dispatch, and `UIMenuSystem.main.setNeedsRebuild()` logic unchanged in behavior onto the container.

- [ ] **Step 4: Delete the split-responder machinery**

Delete `TerminalSoftwareKeyboardProxyView`, its overlay constraints, `sendEscape`, `pressesBegan`, `handleKeyPresses`, the `ObjectiveC` import, and the `UITerminalView.suppressGhosttyInputAccessory()` extension. Remove the startup swizzle call from `GrafttyMobileApp.init()`.

Update `focusKeyboardInput()` and edit-menu refocus to call `terminalView.becomeFirstResponder()`. Keep the terminal as the sole full-size content subview and preserve all existing gestures and callbacks.

- [ ] **Step 5: Update owner wiring**

Rename `shouldInstallKeyboardProxy(clientIsOwner:)` to an eligibility name. Keep `SoftwareKeyboardInput` only for `insertText` and `deleteBackward`; remove `sendEscape`. Route those closures to `SessionClient.sendSoftwareKeyboardText(_:)` and `deleteBackward()` exactly as today.

- [ ] **Step 6: Run focused tests GREEN**

```bash
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-single-responder-dd -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:GrafttyMobileKitTests/TerminalPaneViewTests -only-testing:GrafttyMobileKitTests/SessionClientTests -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests
```

Expected: responder, software input, ownership, selection/paste, and command tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift Sources/GrafttyMobileKit/App/RootView.swift Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift
git commit -m "refactor(ipad): restore libghostty keyboard responder ownership"
```

### Task 6: Apply Fixed Navigation and Collision Rules on Mac

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/Graftty/Views/WorktreeNavFocusedValues.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Modify: `Sources/GrafttyKit/Model/AppState.swift` (comments/spec wording only unless tests expose a real algorithm gap)
- Create: `Tests/GrafttyTests/Views/NavigationCommandShortcutTests.swift`
- Modify: `Tests/GrafttyKitTests/Model/WorktreeNavigationTests.swift`
- Create or modify: `Tests/GrafttyTests/GrafttyAppPaneNavigationTests.swift`

- [ ] **Step 1: Write failing pure command-policy tests**

Extract a UI-free/testable Mac command descriptor policy if necessary. Assert:

- Control-Tab and Control-Shift-Tab always invoke tree-order pane navigation;
- host `next_tab`/`previous_tab` chords are additional pane shortcuts when noncolliding;
- Option variants always invoke attention-first worktree navigation;
- all four fixed chords remain installed with zero/one target and invoke no-op;
- host collisions with either fixed pane or worktree chord receive no Mac keyboard shortcut;
- noncolliding host menu actions retain their shortcuts;
- single-pane cycling leaves focus unchanged and multi-pane cycling wraps.

- [ ] **Step 2: Run and verify RED**

```bash
swift test --filter NavigationCommandShortcutTests
swift test --filter GrafttyAppPaneNavigationTests
swift test --filter WorktreeNavigationTests
```

Expected: fixed Option chords and collision filtering are absent; tab actions still feed worktrees.

- [ ] **Step 3: Implement Mac pane commands**

Render fixed pane aliases from `GrafttyNavigationShortcuts`, route `.nextTab`/`.previousTab` through `handleNavigateTreeOrder`, and attach any noncolliding host-resolved chord as an additional pane command. Change labels to pane terminology.

- [ ] **Step 4: Implement stable fixed worktree commands**

`WorktreeNavCommandButtons` uses the shared Option chords, not Ghostty action chords. It remains active while the main command context exists; `action?(forward)` no-ops when no target instead of disabling the button and releasing its key equivalent. `MainWindow` continues to call the existing attention-first `nextWorktreePath` algorithm.

- [ ] **Step 5: Apply Mac collision arbitration**

Before attaching a host `.keyboardShortcut`, compare normalized `ShortcutChord` identity against all fixed chords. A collision keeps the Mac menu action but omits its shortcut. Use the same precedence constants tested in Task 3.

- [ ] **Step 6: Run focused and broader Mac tests GREEN**

```bash
swift test --filter NavigationCommandShortcutTests
swift test --filter GrafttyAppPaneNavigationTests
swift test --filter WorktreeNavigationTests
swift test --filter GhosttyCommandRegistryTests
```

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/WorktreeNavFocusedValues.swift Sources/Graftty/Views/MainWindow.swift Sources/GrafttyKit/Model/AppState.swift Tests/GrafttyTests/Views/NavigationCommandShortcutTests.swift Tests/GrafttyTests/GrafttyAppPaneNavigationTests.swift Tests/GrafttyKitTests/Model/WorktreeNavigationTests.swift
git commit -m "feat(mac): reserve pane and worktree navigation shortcuts"
```

### Task 7: Migrate Requirements and Generated Specs Atomically

**Files:**
- Modify: `Tests/GrafttyTests/Specs/IosTodo.swift`
- Modify: `Tests/GrafttyTests/Specs/IpadTodo.swift` if affected IDs remain disabled there
- Modify: `Tests/GrafttyTests/Specs/KbdTodo.swift` if affected IDs remain disabled there
- Modify: behavioral tests changed in Tasks 4-6
- Generate: `SPECS.md`

- [ ] **Step 1: Replace superseded requirement text at behavioral tests**

Update the authoritative `@spec` annotations for:

- input: `IOS-6.2`, `IOS-6.6` through `IOS-6.8`, `IOS-6.14`, `IOS-6.16` through `IOS-6.18`, `IOS-11.12`;
- navigation: `KBD-5.1` through `KBD-5.6`, `IPAD-8.1` through `IPAD-8.7`, `IPAD-9.2`, `IPAD-9.3`, `IPAD-9.5`, `IPAD-9.6`, `IPAD-9.9`, `IPAD-9.10`.

Requirements must say `UITerminalView` is the sole hardware responder, supported delegate APIs handle committed software input, Ghostty tab actions navigate panes, fixed Option chords navigate worktrees, and navigation chords consume as no-ops when no alternate target. Remove old proxy/swizzle/Escape-only and Ctrl-Tab-worktree wording from active and disabled inventories.

- [ ] **Step 2: Regenerate and verify specs**

```bash
python3 scripts/generate-specs.py
python3 scripts/generate-specs.py --check
rg -n "keyboard proxy|software-keyboard proxy|next_tab shall select|Ctrl\+Tab.*worktree" SPECS.md Sources Tests
```

Expected: spec check passes and the search returns only explicitly historical/superseded design documents, not active code/tests/SPECS requirements.

- [ ] **Step 3: Run the spec-bearing focused suites**

```bash
swift test --filter WorktreeNavigationTests
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-single-responder-dd -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:GrafttyMobileKitTests/TerminalPaneViewTests -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests -only-testing:GrafttyMobileKitTests/IPadWorktreeNavigationTests
```

- [ ] **Step 4: Commit the requirement migration**

Stage only the spec sources that changed plus `SPECS.md`:

```bash
git add SPECS.md Tests/GrafttyTests/Specs/IosTodo.swift Tests/GrafttyTests/Specs/IpadTodo.swift Tests/GrafttyTests/Specs/KbdTodo.swift
git add Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift Tests/GrafttyMobileKitTests/UI/IPadWorktreeNavigationTests.swift Tests/GrafttyKitTests/Model/WorktreeNavigationTests.swift
git commit -m "docs: migrate keyboard navigation requirements"
```

Omit paths that did not change rather than forcing them into the commit.

### Task 8: Full Verification, Review, Commit Hygiene, and Push

**Files:**
- Review all changes since `e245a5bf`
- No planned production edits; fix only verified review findings

- [ ] **Step 1: Run complete automated verification**

```bash
swift test
python3 scripts/generate-specs.py --check
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -sdk iphonesimulator -configuration Debug -skipPackagePluginValidation -derivedDataPath /tmp/graftty-single-responder-dd -destination 'platform=iOS Simulator,name=iPhone 17' test
git diff --check
```

Expected: macOS package suite, complete iOS suite, generated specs, and whitespace check pass.

- [ ] **Step 2: Run static regression searches**

```bash
rg -n "TerminalSoftwareKeyboardProxyView|suppressGhosttyInputAccessory|class_getInstanceMethod|sendEscapeHandler|handleKeyPresses" Sources Tests
rg -n "Next Worktree.*nextTab|Previous Worktree.*previousTab|navigateWorktree" Sources Tests
```

Expected: no live proxy/swizzle/Escape patch and no Ghostty-tab-as-worktree routing remain.

- [ ] **Step 3: Dispatch final spec and code-quality reviews**

Give reviewers the design spec, this plan, and the commit range `e245a5bf..HEAD`. Resolve every correctness or simplification finding and rerun the affected focused suites. Specifically ask reviewers to look for duplicate input delivery, state-dependent shortcut release, Mac/iPad collision divergence, and loss of render/selection/paste behavior.

- [ ] **Step 4: Verify both repositories are clean and pushed**

```bash
git -C /Users/btucker/projects/graftty-libghostty-fork/libghostty-spm status -sb
git status -sb
git log --oneline origin/ipad-improvements..HEAD
git push origin ipad-improvements
```

Expected: fork branch is already pushed, Graftty worktree is clean after push, and the existing PR updates.

- [ ] **Step 5: Physical iPad smoke test**

This cannot be automated in the simulator. Verify on a connected hardware keyboard:

- Escape, arrows, modified arrows, Backspace, Return, normal text, Option/dead-key input, and IME commit;
- `Ctrl+Tab` / `Ctrl+Shift+Tab` within a worktree;
- `Ctrl+Option+Tab` / `Ctrl+Option+Shift+Tab` across worktrees;
- one-pane/one-worktree commands consume without leaking into the terminal;
- software keyboard, paste/refocus, selection, pinch zoom, and trackpad scrolling.

Record any OS-reserved chord that iPadOS still intercepts; do not add a per-key passthrough workaround.
