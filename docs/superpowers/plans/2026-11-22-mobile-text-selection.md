# Mobile Text Selection and Link Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make terminal text selection in GrafttyMobile behave like iOS text selection (handles, loupe, one finger always scrolls), and make a long-pressed link open on the phone by default with the remote host as a second option.

**Architecture:** `Sources/GhosttyTerminal` already has an overlay-based touch selection (handles, loupe, autoscroll) that is switched off while a host selection delegate is installed. Graftty keeps its delegate (its tap, keyboard and scroll tuning depend on host mode) and the library exposes the overlay selection to hosts. Graftty's mouse-synthesizing `TerminalSelectionController` and its selection pan are deleted; the container begins a library touch selection on long-press and supplies the menu items.

**Tech Stack:** Swift, UIKit, Swift Testing, in-repo `GhosttyTerminal` (libghostty), `GrafttyMobileKit`.

**Spec:** `docs/superpowers/specs/2026-11-22-mobile-text-selection-design.md`

## Global Constraints

- GrafttyMobile only. No Mac behaviour changes; iPad pointer (trackpad/mouse) selection is untouched.
- Touch selection never synthesizes mouse button events.
- One finger always scrolls; only handle drags change a selection.
- Menu titles, exactly: `Open Link`, `Open on <host label>` (fallback `Open on Host`), `Copy Link`, `Copy`, `Select All`, `Paste`.
- "Open Link" opens with `UIApplication.shared.open(_:)`. No in-app browser.
- Every behaviour change is test-first (RED, then GREEN). `@spec` titles follow EARS and contain no literal `"` characters.
- A spec ID appears in at most one behavioural location. Regenerate `SPECS.md` with `scripts/generate-specs.py`; never edit it by hand.
- Build and test only through `scripts/swiftpm`. macOS `scripts/swiftpm test` does not compile UIKit-guarded code, so each task also runs the iOS compile:
  `scripts/swiftpm build --target GrafttyMobileKitTests --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)`
  (use `--target GhosttyTerminalTests` for library tasks). Behavioural proof for UIKit tests is iOS CI: grep each new test's own `passed` line in the log.
- A new test file under `Tests/GrafttyMobileKitTests` must be added to `Apps/GrafttyMobile/GrafttyMobile.xcodeproj`, or it runs zero tests. Prefer adding tests to existing files.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. **Scrolling into history with a selection, then back.** The highlight and handles must track the text, hide when off-screen, and reappear. (Task 1 test `scrollKeepsHostTouchSelection`.)
2. **Long-press on blank space.** No word nearby: the user still gets Paste and Select All, and no empty selection is created. (Task 3 test `blankLongPressFallsBackToPlainMenu`.)
3. **Program redraws under a selection** (Claude Code repainting). The selection must drop instead of copying text the user never saw highlighted. Existing library validation covers it; Task 1 test `redrawUnderHostTouchSelectionDismissesIt` pins it for host mode.
4. **Menu reopened after a handle drag.** Link actions belong to the long-pressed word only; after the user changes the selection they must not offer the old link. (Task 4 test `linkActionsDropAfterSelectionChanges`.)
5. **Pane swapped or session replaced while a menu is open.** Open/Copy actions must not fire against the replacement pane (IOS-11.24, IOS-11.26). (Task 4 keeps `longPressMenuGeneration` checks; existing tests must stay green.)

---

### Task 1: Library — host-driven touch selection that survives scrolling

**Files:**
- Modify: `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift` (delegate setter ~line 146; new public API)
- Modify: `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+TouchSelection.swift` (`beginTouchSelection`, `dismissTouchSelection`, `copyTouchSelection`)
- Modify: `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Scroll.swift` (lines 44 and 106-108)
- Modify: `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift` (`touchesEnded` tap path)
- Test: `Tests/GhosttyTerminalTests/Surface/UIKitHostTextSelectionTests.swift`

**Interfaces:**
- Produces, all `public` on `UITerminalView`, iOS only (`#if !targetEnvironment(macCatalyst)`):
  - `var hasTouchSelection: Bool` — `touchSelection.range != nil`
  - `var touchSelectionText: String?` — `touchSelection.text`
  - `@discardableResult func beginHostTouchSelection(at point: CGPoint, selectAll: Bool = false) -> Bool` — true when a selection now exists
  - `func dismissTouchSelection(restoringViewport: Bool = true)` (existing, made public)
  - `@discardableResult func copyTouchSelection() -> Bool` (existing, made public)

- [ ] **Step 1: Write the failing tests** in `UIKitHostTextSelectionTests`, using the real-surface setup already in `hostRequestContainsViewportTextAndTheOriginalPoint` (window + `InMemoryTerminalSession` + `HostTextSelectionDelegate`). Feed `"alpha beta gamma\r\n"` plus 200 numbered lines so there is scrollback.

  - `hostCanBeginTouchSelectionWithHandles`: with the host delegate installed, `beginHostTouchSelection(at:)` over the word `beta` returns true; `hasTouchSelection`; `touchSelectionText == "beta"`; `touchSelection.overlay` is non-nil with both handles not hidden; `surface.hasSelection() == false` (no ghostty mouse selection).
  - `scrollKeepsHostTouchSelection`: after selecting, drive `handleTouchScrollGesture` through `.began`/`.changed` (or `surface.scrollToRow` plus a tick) — `hasTouchSelection` stays true and `touchSelectionText` is unchanged; after scrolling the word off-screen both handles are hidden; scrolling back unhides them.
  - `redrawUnderHostTouchSelectionDismissesIt`: after selecting, feed `ESC[2J ESC[H "zzzz"` and call `refreshTouchSelection()` past the 0.25 s validation interval — `hasTouchSelection == false`.
  - `tapDismissesHostTouchSelectionWithoutTogglingKeyboard`: with a selection, run the tap path (`touchesEnded` tap candidate) — selection is gone and `softwareKeyboard.isVisible` is unchanged.
  - `blankPointBeginsNothing`: on an empty screen, `beginHostTouchSelection(at:)` returns false and `hasTouchSelection == false`.
  - `copyTouchSelectionWritesCleanText`: `copyTouchSelection()` returns true, `UIPasteboard.general.string == "beta"`, selection gone.
  - Update `hostSelectionDelegateOwnsTheExistingLongPress`: it stays as is (tap recognizers remain disabled and `maximumNumberOfTouches == 1` in host mode).

- [ ] **Step 2: Run the iOS compile for `GhosttyTerminalTests`.** Expected: FAIL — `beginHostTouchSelection`, `hasTouchSelection`, `touchSelectionText` not found.

- [ ] **Step 3: Implement.**
  - `beginTouchSelection(at:selectAll:selectLine:)`: replace the `usesInlineTextSelection` guard with `touchSelection.enabled`. `beginHostTouchSelection` calls it and returns `touchSelection.range != nil`. In host mode the function must not present the library's edit menu until the range exists (it already presents after assigning; keep).
  - `UITerminalView.delegate` setter: stop dismissing the touch selection when a host delegate is installed.
  - `handleTouchScrollGesture` `.began` (line ~106) and `handleScrollWheelGesture` `.began` (line 44): do not dismiss an existing touch selection; `refreshTouchSelection()` already repositions the overlay per tick.
  - `touchesEnded` host tap path: if `touchSelection.range != nil`, call `dismissTouchSelection()` and return before `sendTapClick`/keyboard toggle.
  - Make `dismissTouchSelection` and `copyTouchSelection` public; add the two computed properties.

- [ ] **Step 4: Run the iOS compile again.** Expected: build succeeds. Run `scripts/swiftpm test --filter GhosttyTerminalTests`. Expected: PASS (macOS suites unaffected).

- [ ] **Step 5: Commit** — `Let hosts drive the terminal's touch selection overlay`.

---

### Task 2: Library — host supplies the selection menu

**Files:**
- Modify: `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+TouchMenu.swift` (`touchSelectionMenu(at:suggestedActions:)`, `presentTouchSelectionMenu`)
- Modify: `Sources/GrafttyMobileKit/Terminal/MobileTerminalInputView.swift`
- Test: `Tests/GhosttyTerminalTests/Surface/UIKitHostTextSelectionTests.swift`

**Interfaces:**
- Consumes: Task 1 API.
- Produces: `MobileTerminalInputView.selectionMenuItems: ((TerminalTouchSelectionMenuContext) -> [UIMenuElement])?`; when set, `touchSelectionMenuItems(for:)` returns its result instead of the library default.

- [ ] **Step 1: Write the failing test** `hostSelectionMenuComesFromTheOverride`: a `UITerminalView` subclass overriding `touchSelectionMenuItems(for:)` to return one `UIAction(title: "Probe")`; with host delegate installed and a selection begun, `touchSelectionMenu(at:suggestedActions: [])` has children titles `["Probe"]`, and the context's `selectedText == "beta"`. Second test `handleDragEndRepresentsMenuInHostMode`: after `finishTouchSelectionDrag(at:)`, `touchSelection.menuPoint` is set and `presentTouchSelectionMenu` did not early-return (assert via the `willPresentMenuFor` flag `touchSelection.menuVisible` when a window is attached, as existing inline tests do; if no inline test does this, assert `touchMenuTargetRect(at:)` equals `overlay.menuAvoidanceRect`).

- [ ] **Step 2: Run the iOS compile.** Expected: FAIL only if host mode gates the menu path; if it compiles, run on simulator/CI and expect the title assertion to fail where host mode bypasses the override. If both already pass, keep the tests as pins and skip Step 3's library edit.

- [ ] **Step 3: Implement.** Remove any `usesInlineTextSelection` gate on the selection-menu path so it works in host mode. Add `selectionMenuItems` and the `touchSelectionMenuItems(for:)` override to `MobileTerminalInputView`.

- [ ] **Step 4: Run** the iOS compile for both `GhosttyTerminalTests` and `GrafttyMobileKitTests`. Expected: build succeeds.

- [ ] **Step 5: Commit** — `Route the touch selection menu through the host view`.

---

### Task 3: Graftty — long-press selects the word with handles; delete the mouse-faking mode

**Files:**
- Delete: `Sources/GrafttyMobileKit/Terminal/TerminalSelectionController.swift`, `Tests/GrafttyMobileKitTests/Terminal/TerminalSelectionControllerTests.swift` (and their entries in `Apps/GrafttyMobile/GrafttyMobile.xcodeproj/project.pbxproj`; check `Apps/GrafttyMobile/project.yml` for whether the project is generated)
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalInputContainerView+SelectionMenu.swift`
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalInputContainerView.swift` (lines 242, 407, 416-523, 621-633, 683-696, 724-730)
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalInputContainerView+TestSeams.swift`
- Modify: `Sources/GrafttyMobileKit/Terminal/SurfaceProxy.swift` only if members become unused
- Test: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`, `Tests/GrafttyMobileKitTests/App/MobilePaneAttentionTests.swift`

**Interfaces:**
- Consumes: Task 1 API; Task 2 `selectionMenuItems`.
- Produces on `TerminalInputContainerView`:
  - `func selectionMenuElements(for context: TerminalTouchSelectionMenuContext, hasPasteContent: Bool) -> [UIMenuElement]` — Copy, Select All, Paste (Task 4 prepends link items)
  - `longPressUIMenu(for:hasPasteContent:)` keeps its signature; it loses `Select`.
  - `var longPressSelectedText: String?` — the text selected by the latest long-press
  - Test seam `selectionMenuActionTitlesForTesting(selectedText: String, hasPasteContent: Bool) -> [String]`

- [ ] **Step 1: Rewrite the specs as failing tests** in `TerminalPaneViewTests` (replace the old IOS-11.1/11.4 tests; move the IDs, do not duplicate them):

  - `@spec IOS-11.1: When the user presses and holds terminal text on mobile, the application shall select the word under the press, show a handle at each end of the selection, and present an edit menu containing Copy, Select All, and Paste when the clipboard holds text or an image, without synthesizing mouse input.` — real surface with `"alpha beta gamma"`; deliver `terminalDidRequestTextSelection` at `beta`; expect `terminalView.hasTouchSelection`, `touchSelectionText == "beta"`, `surface.hasSelection() == false`, titles `["Copy", "Select All", "Paste"]` (and `["Copy", "Select All"]` without paste content).
  - `@spec IOS-11.2: If the user presses and holds a blank region of a mobile terminal with no text nearby, then the application shall present Select All and Paste without creating a selection.` — test `blankLongPressFallsBackToPlainMenu`: empty screen; `hasTouchSelection == false`; `longPressMenuActionTitlesForTesting(hasPasteContent: true) == ["Select All", "Paste"]`.
  - `@spec IOS-11.3: When the user chooses Select All from a mobile terminal menu, the application shall select all terminal text including scrollback and show its handles.` — invoke the action; `touchSelectionText` contains first and last fed lines.
  - `@spec IOS-11.4: While a mobile terminal has a text selection, one-finger drags outside the selection handles shall scroll the terminal or checkpoint canvas and shall leave the selection unchanged.` — after selecting: every pan in `terminalView.gestureRecognizers`, `snapshotScrollView.panGestureRecognizer` and `snapshotScrollView.historyIntentPan` still allows direct touches (`allowedTouchTypes` contains `.direct`), `applicationScrollRecognizer.isEnabled` is unchanged, and no recognizer named `selectionPanRecognizer` exists on the container.
  - `@spec IOS-11.5: When the user finishes dragging a selection handle on mobile, the application shall present the edit menu clear of the selection and its handles.` — after `finishTouchSelectionDrag`, `touchMenuTargetRect(at:)` equals the overlay's `menuAvoidanceRect`.
  - `@spec IOS-11.6: When the user chooses Copy from a mobile terminal selection menu, the application shall write the selected text to the pasteboard and clear the selection; if nothing is selected, then the pasteboard shall not be modified.`
  - `@spec IOS-11.7: When the user taps outside a mobile terminal selection or presses a terminal control-bar key, the application shall clear the selection without modifying the pasteboard.` — `cancelActiveSelectionIfAny()` clears a touch selection.
  - `@spec IOS-11.10: A mobile terminal selection shall belong to its own pane and shall not affect the selection of any other pane.` — two containers; selecting in one leaves the other's `hasTouchSelection == false`.
  - `@spec IOS-11.14`: delete the test and spec (edge autoscroll is the library's; mouse anchor no longer exists).
  - `MobilePaneAttentionTests.selectionAndZoomDoNotNavigateBack` (IOS-4.44): drive selection through `terminalView.beginHostTouchSelection` instead of `enterSelectionModeForTesting`.
  - Update or delete `selectionModeKeepsIndirectScrollingEnabled`, `selectionModeStripsDirectTouchesFromScrollPans`, `trackpadScrollDoesNotDriveSelection` (IOS-6.46 must keep a test: a two-finger trackpad scroll does not begin a selection), `selectionMenuDismissalDoesNotConsumePendingPasteRefocus` (IOS-11.12 keeps its paste-refocus test; drop the `selectionMenu` interaction half), `detachedSurfaceClearsSelectionAndLinks` (expect `hasTouchSelection == false` after detach).

- [ ] **Step 2: Run the iOS compile for `GrafttyMobileKitTests`.** Expected: FAIL on missing seams/removed symbols.

- [ ] **Step 3: Implement.**
  - `terminalDidRequestTextSelection`: resolve the link as today (Task 4 keeps this), then `terminalView.beginHostTouchSelection(at: request.sourcePoint)`. On true, set `longPressSelectedText = terminalView.touchSelectionText` (the library presents the menu). On false, present the existing `longPressMenu`.
  - Wire `terminalView.selectionMenuItems = { [weak self] ctx in self?.selectionMenuElements(for: ctx, hasPasteContent: UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages) ?? [] }` at setup.
  - Menu actions: Copy → `terminalView.copyTouchSelection()`; Select All → `terminalView.beginHostTouchSelection(at: ctx.sourcePoint, selectAll: true)`; Paste → `terminalView.dismissTouchSelection()` then the existing `performPaste(for:)` (keeps IOS-11.8 image upload and IOS-11.12 refocus).
  - Delete `selectionController`, `selectionMenu`, `selectionPanRecognizer` and its `require(toFail:)` wiring, `enterSelectionMode`/`exitSelectionMode`, `selectionModeSavedTouchTypes`, `handleSelectionPan`, `performSelectAtLongPressPoint`, `performCopy`, `performCancelSelection`, and their test seams.
  - Replace every `selectionController.isActive` read: back-swipe guards (lines 621, 690, 696) use `terminalView.hasTouchSelection`; `applicationScrollRecognizer` and `followerPinchGesture` enablement lose their selection term; the link probe guard keeps `surface.isMouseCaptured` and `surface.hasSelection()`.
  - `cancelActiveSelectionIfAny()` → `terminalView.dismissTouchSelection()`.
  - Detach/reset paths (lines 449-460, 724-730) dismiss the touch selection.

- [ ] **Step 4: Run** the iOS compile (expected: succeeds) and `scripts/swiftpm test` (expected: PASS, no regressions).

- [ ] **Step 5: Run `scripts/generate-specs.py`; commit** — `Select terminal text on mobile with native handles`.

---

### Task 4: Graftty — Open Link locally, Open on host second

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalInputContainerView.swift` (near line 438-441)
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalInputContainerView+SelectionMenu.swift`
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` (init, lines 217 and 249)
- Modify: `Sources/GrafttyMobileKit/Terminal/SingleSessionView.swift` (line ~1483)
- Test: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`

**Interfaces:**
- Consumes: Task 3 `selectionMenuElements`, `longPressSelectedText`, `longPressURL`, `longPressMenuGeneration`.
- Produces:
  - `TerminalInputContainerView.openURLLocally: (URL) -> Void` — default `{ UIApplication.shared.open($0) }`
  - `TerminalInputContainerView.hostLabel: String?`
  - `TerminalPaneView(…, hostLabel: String? = nil, …)`, assigned in `makeUIView` and `updateUIView`; `SingleSessionView` passes `step.host.label`.
  - `func linkMenuElements(for generation: UInt) -> [UIMenuElement]` — empty when `longPressURL == nil`

- [ ] **Step 1: Write the failing tests** (update the IOS-11.13 test, add two):

  - `@spec IOS-11.13: When the user presses and holds a displayed HTTP or HTTPS URL on mobile, the application shall offer Open Link, which opens the complete URL on the device, then an action naming the host, which routes it through the originating pane browser, then Copy Link, ahead of its text-selection actions. Pressing ordinary text shall not offer link actions.` — with `hostLabel = "Studio"` titles begin `["Open Link", "Open on Studio", "Copy Link", "Copy", "Select All"]`; invoking `Open Link` calls `openURLLocally` with the URL and not `openURL`; invoking `Open on Studio` calls `openURL` and not `openURLLocally`; with `hostLabel == nil` (or empty) the second title is `Open on Host`; ordinary text gives no link titles.
  - `linkActionsDropAfterSelectionChanges`: after the long-press on a URL, build `selectionMenuElements` with a context whose `selectedText` differs from `longPressSelectedText` — no link titles.
  - Blank-space fallback menu on a URL-less press has no link titles; a link press where `beginHostTouchSelection` fails still lists the three link actions first in `longPressUIMenu`.
  - Existing IOS-11.23, 11.24, 11.25, 11.26 tests stay and must pass; adjust only their expected title lists.

- [ ] **Step 2: Run the iOS compile.** Expected: FAIL — `openURLLocally`, `hostLabel` not found.

- [ ] **Step 3: Implement.** `linkMenuElements(for:)` builds the three actions with images `safari`, `macbook.and.iphone`, `doc.on.doc`; every handler re-checks `longPressMenuGeneration == generation` before acting. `selectionMenuElements` prepends them only when `context.selectedText == longPressSelectedText`. `longPressUIMenu` prepends them too. Reset `openURLLocally` to a no-op and `hostLabel` to nil wherever `openURL` is reset (line 449). A plain tap or Cmd-click on a link (`terminalDidRequestOpenURL`) is unchanged.

- [ ] **Step 4: Run** the iOS compile (succeeds) and `scripts/swiftpm test` (PASS).

- [ ] **Step 5: Run `scripts/generate-specs.py`; commit** — `Open long-pressed terminal links on the device by default`.

---

### Task 5: Double-tap and triple-tap selection

**Files:**
- Modify: `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+TouchGestures.swift` (`updateTouchSelectionGestures`, `handleSelectionTap`)
- Modify: `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift` (tap candidate)
- Test: `Tests/GhosttyTerminalTests/Surface/UIKitHostTextSelectionTests.swift`, `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: in host mode the 2-tap and 3-tap recognizers are enabled; the 1-tap recognizer stays disabled (the host tap path keeps owning single taps).

- [ ] **Step 1: Failing tests.** Library: update `hostSelectionDelegateOwnsTheExistingLongPress` — in host mode `tapRecognizers[0].isEnabled == false`, `[1]` and `[2]` are enabled; `handleSelectionTap` for 2 taps over `beta` yields `touchSelectionText == "beta"`; for 3 taps yields the whole row. Graftty: `@spec IOS-11.27: When the user double-taps terminal text on mobile, the application shall select that word with handles, and when the user triple-taps, the application shall select that line.` (confirm 11.27 is unused with `grep -rn "IOS-11.27"`; otherwise take the next free number).

- [ ] **Step 2: iOS compile / run.** Expected: assertion failures on recognizer enablement.

- [ ] **Step 3: Implement.** Enable taps 2 and 3 when `touchSelection.enabled`, whatever the host mode; `handleSelectionTap` guards on `touchSelection.enabled` for counts 2 and 3. The first tap of a double-tap still reaches the host tap path (click plus keyboard toggle, as today); do not add a single-tap delay. After a double-tap begins a selection, the second `touchesEnded` must not dismiss it: clear `softwareKeyboard.tapCandidateArmed` in `handleSelectionTap`.

- [ ] **Step 4: Run** both iOS compiles and `scripts/swiftpm test`. Expected: PASS.

- [ ] **Step 5: `scripts/generate-specs.py`; commit** — `Select words and lines by double and triple tap on mobile`.

---

### Task 6: Verify on a device-like surface and ship

- [ ] **Step 1:** Update the design doc's Approaches section to say the host delegate is kept and the library overlay is exposed to it (the user-visible design is unchanged).
- [ ] **Step 2:** Run the app in the simulator (isolated dev instance recipe) and check by hand: long-press word → handles + menu; drag each handle with loupe; one-finger scroll with selection held, in both live and checkpoint-canvas panes; tap to dismiss; double/triple tap; link menu order and both open paths; a mouse-capturing TUI (e.g. `htop`). Record what was and was not checked; touch input cannot be synthesized from an agent shell, so hand anything unverified to the user as a short checklist.
- [ ] **Step 3:** `scripts/swiftpm test`, `scripts/generate-specs.py --check`, both iOS compiles.
- [ ] **Step 4:** Run `/code-review xhigh --fix`, then `/simplify`.
- [ ] **Step 5:** Open the PR; confirm iOS CI is green by grepping each new test's `passed` line. Save any failed log before rerunning.
