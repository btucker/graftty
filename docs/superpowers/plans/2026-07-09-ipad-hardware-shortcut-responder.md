# iPad Hardware Shortcut Responder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make iPad app-level hardware keyboard shortcuts publish from the active terminal input responder, refresh dynamically, and support Ghostty's `Ctrl+Tab` worktree-navigation defaults.

**Architecture:** Preserve the existing semantic command registry and terminal input routing. Add explicit mobile keybinding provenance so only bundled fallback bindings gain aliases, expand those bindings into deduplicated command descriptors, and move `UIKeyCommand` publication to the actual `UIKeyInput` first responder with a synchronous request for a UIKit main-menu-system rebuild when its effective table changes.

**Tech Stack:** Swift 6, SwiftUI, UIKit `UIKeyCommand`/`UIKeyInput`, Swift Testing, Swift Package Manager, Xcode iOS simulator tests, `scripts/generate-specs.py`.

---

## File Structure

| File | Responsibility | Planned change |
|------|----------------|----------------|
| `Sources/GrafttyProtocol/Keybinds/GhosttyDefaultKeybinds.swift` | UI-free bundled Ghostty shortcut snapshot | Preserve the primary bridge and add ordered default aliases for next/previous worktree. |
| `Sources/GrafttyMobileKit/Session/GhosttyKeybindingsFetcher.swift` | Fetch and cache host-resolved keybindings | Return a bridge plus explicit `.loading`, `.hostResolved`, or `.bundledFallback` source. |
| `Sources/GrafttyMobileKit/App/IPadRootLayout.swift` | Own host presentation and semantic command context | Store/pass the provenance-bearing set and clear it to `.loading` during host refresh. |
| `Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift` | Convert semantic actions/chords to UI commands | Expand fallback aliases, preserve host authority, deduplicate chords, and create stable IDs. |
| `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift` | Bridge terminal UI and keyboard responder | Publish commands from `TerminalSoftwareKeyboardProxyView` and request a UIKit main-menu-system rebuild on effective changes. |
| `Tests/GrafttyProtocolTests/Keybinds/GhosttyDefaultKeybindsTests.swift` | Pure default coverage | Pin ordered `Ctrl+Tab` aliases and primary-before-alias behavior. |
| `Tests/GrafttyMobileKitTests/Session/GhosttyKeybindingsFetcherTests.swift` | Fetch/cache coverage | Verify provenance for success, empty success, failure, cache hit, and invalidation. |
| `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift` | Command construction | Verify loading state, host-only chords, fallback aliases, enablement, stable IDs, and collision precedence. |
| `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift` | UIKit responder behavior | Verify late install, menu-rebuild requests, removal, and exact dispatch from the proxy. |
| `SPECS.md` | Generated requirement inventory | Regenerate for tightened `IPAD-9.9` and new `IPAD-9.10`. |

No new production files are needed. The provenance type stays mobile-specific beside the fetch/cache owner; aliases stay protocol-level without importing UIKit.

### Task 1: Represent Ordered Ghostty Default Aliases

**Files:**
- Modify: `Tests/GrafttyProtocolTests/Keybinds/GhosttyDefaultKeybindsTests.swift`
- Modify: `Sources/GrafttyProtocol/Keybinds/GhosttyDefaultKeybinds.swift`

- [ ] **Step 1: Write failing alias tests**

```swift
@Test func worktreeNavigationIncludesGhosttyControlTabAliases() {
    #expect(GhosttyDefaultKeybinds.hardwareChords(for: .nextTab) == [
        ShortcutChord(key: "bracketright", modifiers: [.command, .shift]),
        ShortcutChord(key: "tab", modifiers: [.control]),
    ])
    #expect(GhosttyDefaultKeybinds.hardwareChords(for: .previousTab) == [
        ShortcutChord(key: "bracketleft", modifiers: [.command, .shift]),
        ShortcutChord(key: "tab", modifiers: [.control, .shift]),
    ])
}

@Test func actionsWithoutAliasesReturnOnlyTheirPrimaryChord() {
    #expect(GhosttyDefaultKeybinds.hardwareChords(for: .newSplitRight) == [
        ShortcutChord(key: "d", modifiers: [.command]),
    ])
    #expect(GhosttyDefaultKeybinds.hardwareChords(for: .newSplitLeft).isEmpty)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run `swift test --filter GhosttyDefaultKeybindsTests`.

Expected: compile failure because `hardwareChords(for:)` does not exist.

- [ ] **Step 3: Implement the ordered alias API**

Keep `chords` and `bridge` unchanged. Add:

```swift
public static let aliases: [GhosttyAction: [ShortcutChord]] = [
    .nextTab: [ShortcutChord(key: "tab", modifiers: [.control])],
    .previousTab: [ShortcutChord(key: "tab", modifiers: [.control, .shift])],
]

public static func hardwareChords(for action: GhosttyAction) -> [ShortcutChord] {
    [chords[action]].compactMap { $0 } + aliases[action, default: []]
}
```

Primary chords intentionally precede aliases for deterministic collision precedence.

- [ ] **Step 4: Run tests and verify GREEN**

```bash
swift test --filter GhosttyDefaultKeybindsTests
swift test --filter GhosttyCommandRegistryTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyProtocol/Keybinds/GhosttyDefaultKeybinds.swift Tests/GrafttyProtocolTests/Keybinds/GhosttyDefaultKeybindsTests.swift
git commit -m "feat(ipad): preserve ghostty worktree shortcut aliases"
```

### Task 2: Carry Keybinding Provenance Through Fetch, Cache, and Layout

**Files:**
- Modify: `Tests/GrafttyMobileKitTests/Session/GhosttyKeybindingsFetcherTests.swift`
- Modify: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`
- Modify: `Sources/GrafttyMobileKit/Session/GhosttyKeybindingsFetcher.swift`
- Modify: `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`
- Modify: `Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift`

- [ ] **Step 1: Write failing provenance tests**

Change fetcher assertions to consume a result set and add the successful-empty case:

```swift
@Test func validJSONIsHostResolved() async {
    let set = await GhosttyKeybindingsFetcher.fetchUncached(
        baseURL: baseURL,
        session: Self.session(statusCode: 200, body: #"{"bindings":{"new_split:right":{"key":"d","modifiers":8}}}"#)
    )
    #expect(set.source == .hostResolved)
    #expect(set.bridge[.newSplitRight] == ShortcutChord(key: "d", modifiers: [.command]))
}

@Test func successfulEmptyResponseDoesNotBecomeFallback() async {
    let set = await GhosttyKeybindingsFetcher.fetchUncached(
        baseURL: baseURL,
        session: Self.session(statusCode: 200, body: #"{"bindings":{}}"#)
    )
    #expect(set.source == .hostResolved)
    #expect(set.bridge.allChords.isEmpty)
}

@Test func missingEndpointIsBundledFallback() async {
    let set = await GhosttyKeybindingsFetcher.fetchUncached(
        baseURL: baseURL,
        session: Self.session(statusCode: 404, body: "Not Found")
    )
    #expect(set.source == .bundledFallback)
    #expect(set.bridge.allChords == GhosttyDefaultKeybinds.chords)
}
```

Update cache tests to assert source survives cache hits. Update the layout test to require `IPadRootLayout.keybindingSetForStartingHostRefresh().source == .loading` and an empty bridge.

- [ ] **Step 2: Run tests and verify RED**

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/GhosttyKeybindingsFetcherTests -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests
```

Expected: compile failure because the fetcher still returns `GhosttyKeybindBridge` and no source type exists.

- [ ] **Step 3: Add the provenance-bearing type**

In `GhosttyKeybindingsFetcher.swift`, add:

```swift
public enum MobileGhosttyKeybindingSource: Sendable, Equatable {
    case loading
    case hostResolved
    case bundledFallback
}

public struct MobileGhosttyKeybindingSet: Sendable {
    public let bridge: GhosttyKeybindBridge
    public let source: MobileGhosttyKeybindingSource

    static let loading = Self(bridge: .empty, source: .loading)
    static let bundledFallback = Self(bridge: GhosttyDefaultKeybinds.bridge, source: .bundledFallback)
}
```

The type and its readable state are public because the existing
`GhosttyKeybindingsFetcher.fetch(baseURL:)` API is public and Swift forbids a
public method from returning an internal type. Keep construction internal to
the fetcher through internal initializers/static factories. Return
`.hostResolved` for every successfully decoded response, including an empty
dictionary. Return `.bundledFallback` only when fetching/decoding returns nil.

- [ ] **Step 4: Migrate the cache**

Change `byBaseURL`, inflight tasks, `bridge(for:)` (rename to `keybindingSet(for:)`), `fetch`, and `fetchUncached` to carry `MobileGhosttyKeybindingSet`. Cache only `.hostResolved` results, preserving the existing retry behavior for failures.

- [ ] **Step 5: Migrate layout and command context**

Replace `@State private var keybindBridge` with a set initialized to `.loading`. Rename `keybindBridgeForStartingHostRefresh()` to `keybindingSetForStartingHostRefresh()`, assign `.loading` before each fetch, and assign the returned set afterward.

Change `MobileGhosttyCommandContext.keybindBridge` to `keybindingSet`. Use `context.keybindingSet.bridge` for existing scene and single-chord hardware rendering so this task does not yet change aliases.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Step 2 command again.

Expected: fetcher/cache/layout tests pass and migrated command fixtures remain green.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/GhosttyKeybindingsFetcher.swift Sources/GrafttyMobileKit/App/IPadRootLayout.swift Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift Tests/GrafttyMobileKitTests/Session/GhosttyKeybindingsFetcherTests.swift Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift
git commit -m "refactor(ipad): retain keybinding source provenance"
```

### Task 3: Expand and Deduplicate Hardware Command Aliases

**Files:**
- Modify: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`
- Modify: `Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift`

- [ ] **Step 1: Write failing construction tests**

Add one test with the full requirement title:

```swift
@Test("""
@spec IPAD-9.10: Mobile keybinding fetch and cache results shall retain loading, host-resolved, or bundled-fallback provenance; bundled fallback hardware commands shall retain Ghostty's Ctrl+Tab and Ctrl+Shift+Tab worktree-navigation aliases in addition to the Command-bracket aliases, while host-resolved commands shall not gain fallback aliases.
""")
func ipad_9_10_fallbackCommandsIncludeWorktreeAliases() {
    let context = MobileGhosttyCommandContext(
        keybindingSet: .bundledFallback,
        perform: { _ in },
        isEnabled: { $0 == .nextTab || $0 == .previousTab }
    )
    let commands = MobileGhosttyCommandButtons.hardwareKeyboardCommands(for: context)
    #expect(commands.contains { $0.input == "\t" && $0.modifierFlags == [.control] })
    #expect(commands.contains { $0.input == "\t" && $0.modifierFlags == [.control, .shift] })
    #expect(commands.contains { $0.input == "]" && $0.modifierFlags == [.command, .shift] })
    #expect(commands.contains { $0.input == "[" && $0.modifierFlags == [.command, .shift] })
}
```

Also test `Cmd+D`, host-resolved custom chord without aliases, host-resolved empty bindings, disabled filtering, unique alias IDs, and primary-wins collision behavior. If collision cannot be injected through the shared table, extract an internal pure deduplication helper and test it directly.

- [ ] **Step 2: Run tests and verify RED**

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests
```

Expected: alias assertions fail because hardware construction still reads one bridge chord per action.

- [ ] **Step 3: Implement source-aware expansion**

For each enabled action: emit none for `.loading`; use only `bridge[action]` for `.hostResolved`; use `GhosttyDefaultKeybinds.hardwareChords(for:)` for `.bundledFallback`.

Convert with `UIKeyCommandInputFromChord`. Create stable IDs from semantic action, input, and normalized modifier raw value; do not use randomized `hashValue`.

- [ ] **Step 4: Deduplicate with global primary precedence**

Build candidates in two global phases: first emit every action's primary chord
in shared registry order, then emit every fallback alias in shared registry
order. Insert normalized input/modifier identity into a `Set` and append only
the first occurrence. This guarantees any primary wins over any alias, even
when the alias belongs to an earlier registry action. Keep the surviving
descriptor's action closure. The collision test must inject an earlier
action's alias that matches a later action's primary and assert the later
primary survives.

- [ ] **Step 5: Run tests and verify GREEN**

Run the Step 2 command again.

Expected: the suite passes, including `Cmd+D`, Control-Tab aliases, host authority, and collisions.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift
git commit -m "feat(ipad): expand fallback hardware shortcut aliases"
```

### Task 4: Publish Dynamic Commands From the Actual First Responder

**Files:**
- Modify: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`

- [ ] **Step 1: Write failing responder lifecycle tests**

Replace parent-only assertions with proxy assertions:

```swift
@Test("""
@spec IPAD-9.9: The active iPad terminal input responder shall publish app-level Ghostty shortcuts as UIKeyCommands and synchronously request a UIKit menu-system rebuild whenever the effective command identities, titles, inputs, or modifiers change, so hardware-keyboard commands remain current while terminal input owns first responder status.
""")
func activeInputResponderPublishesLateInstalledCommands() {
    let container = TerminalInputContainerView(frame: .zero)
    #expect(container.inputProxy.keyCommands == nil)
    #expect(container.inputProxy.keyCommandUpdateRequestCountForTesting == 0)
    container.hardwareKeyboardCommands = [Self.command(id: "split", input: "d", modifiers: [.command])]
    #expect(container.inputProxy.keyCommands?.first?.input == "d")
    #expect(container.inputProxy.keyCommandUpdateRequestCountForTesting == 1)
}
```

Add tests that equivalent descriptors update closures without a rebuild
request; changed identity, title, input, or modifiers request a rebuild;
removal requests a rebuild and returns nil; proxy dispatch requires an exact
normalized chord; and the container no longer owns the command table. Title
participates in the effective signature because UIKit displays it as both
`title` and `discoverabilityTitle`.

- [ ] **Step 2: Run tests and verify RED**

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/TerminalPaneViewTests
```

Expected: failure because the proxy does not publish commands or expose
menu-rebuild-request observation.

- [ ] **Step 3: Forward assignments to the proxy**

Replace the container's stored array and `keyCommands` override with:

```swift
public var hardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] {
    get { inputProxy.hardwareKeyboardCommands }
    set { inputProxy.hardwareKeyboardCommands = newValue }
}
```

Move UIKeyCommand construction, selector dispatch, exact-match lookup, and normalized modifier handling to `TerminalSoftwareKeyboardProxyView`.

- [ ] **Step 4: Add effective-table rebuild requests**

On the main-actor proxy, replace the backing descriptors and recompute the
effective signature before synchronously requesting a main-menu-system rebuild
through `UIMenuSystem.main.setNeedsRebuild()`. Current UIKit does not expose
responder-level key-command invalidation; requesting a main-menu-system rebuild
is the supported way to make UIKit query the responder's `keyCommands` again.
Compare a private `Equatable` signature containing ID, title, input, and
normalized modifiers; ignore closures for equality. Increment
`keyCommandUpdateRequestCountForTesting` immediately before the UIKit call. Do
not defer the rebuild request asynchronously.

- [ ] **Step 5: Run tests and verify GREEN**

Run the Step 2 command again.

Expected: terminal responder, software keyboard, gesture, selection, and paste tests pass.

- [ ] **Step 6: Run combined shortcut tests**

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/TerminalPaneViewTests -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests -only-testing:GrafttyMobileKitTests/GhosttyKeybindingsFetcherTests
```

Expected: all selected suites pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift
git commit -m "fix(ipad): refresh shortcuts on terminal input responder"
```

### Task 5: Regenerate Specs and Run Full Verification

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Regenerate specs**

Run `python3 scripts/generate-specs.py`.

Expected: `SPECS.md` contains tightened `IPAD-9.9` and new `IPAD-9.10`, with no duplicate-ID error.

- [ ] **Step 2: Check generated diff**

```bash
git diff --check
git diff -- SPECS.md
```

Expected: only intended iPad requirements change.

- [ ] **Step 3: Run package regressions**

```bash
swift test --filter GhosttyDefaultKeybindsTests
swift test --filter GhosttyCommandRegistryTests
swift test --filter KeyboardShortcutFromChordTests
```

Expected: all pass.

- [ ] **Step 4: Run the complete iOS simulator target**

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test
```

Expected: `** TEST SUCCEEDED **` with no failing mobile tests.

- [ ] **Step 5: Verify generated specs and status**

```bash
python3 scripts/generate-specs.py --check
git status --short
```

Expected: spec check exits zero and status contains only intended changes.

- [ ] **Step 6: Commit documentation and specs**

```bash
git add SPECS.md docs/superpowers/specs/2026-07-09-ipad-hardware-shortcut-responder-design.md docs/superpowers/plans/2026-07-09-ipad-hardware-shortcut-responder.md
git commit -m "docs: specify ipad hardware shortcut lifecycle"
```

- [ ] **Step 7: Inspect final history**

```bash
git log --oneline -8
git diff HEAD~1..HEAD --check
git status --short
```

Expected: the focused documentation commit follows the implementation commits
and the worktree is clean.
