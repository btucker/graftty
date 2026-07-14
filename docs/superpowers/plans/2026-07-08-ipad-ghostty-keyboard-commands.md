# iPad Ghostty Keyboard Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make iPad hardware-keyboard commands use the same host-resolved Ghostty action keybindings as Mac for the first-pass supported pane and worktree commands.

**Architecture:** Move the pure keybinding model into `GrafttyProtocol` so Mac, host web routes, and mobile can share it without making `GrafttyMobileKit` depend on `GrafttyKit`. Add a shared command registry in `GrafttyProtocol` that both Mac command rendering and iPad command rendering consume, and add a small shared SwiftUI helper target for `ShortcutChord` to `KeyboardShortcut` translation. Add a host endpoint that returns the Mac-resolved action-to-chord map, fetch/cache that map on iPad, and route supported iPad scene commands through shared command metadata into `IPadAppState` and `PaneEnvironment`.

**Tech Stack:** Swift, SwiftUI scene commands, GrafttyProtocol wire models, shared SwiftUI command helper target, GrafttyKit WebServer, GrafttyMobileKit, Swift Testing/XCTest, xcodebuild iOS simulator tests.

---

## File Structure

Shared model:
- Move from `Sources/GrafttyKit/Keybinds/GhosttyAction.swift` to `Sources/GrafttyProtocol/Keybinds/GhosttyAction.swift`.
- Move from `Sources/GrafttyKit/Keybinds/ShortcutChord.swift` to `Sources/GrafttyProtocol/Keybinds/ShortcutChord.swift`.
- Move from `Sources/GrafttyKit/Keybinds/GhosttyKeybindBridge.swift` to `Sources/GrafttyProtocol/Keybinds/GhosttyKeybindBridge.swift`.
- Move tests from `Tests/GrafttyKitTests/Keybinds/*` to `Tests/GrafttyProtocolTests/Keybinds/*`.

Shared SwiftUI command helpers:
- Create a new package target `GrafttyCommandUI` with `Sources/GrafttyCommandUI/KeyboardShortcutFromChord.swift`. The target depends on `GrafttyProtocol`, imports SwiftUI, and owns the one shared `ShortcutChord` to `KeyboardShortcut` translator.
- Modify `Package.swift` so `Graftty` and `GrafttyMobileKit` both depend on `GrafttyCommandUI`.
- Delete or leave a compatibility wrapper in `Sources/Graftty/Terminal/KeyboardShortcutFromChord.swift` only if needed during migration. The implementation must live in `GrafttyCommandUI`; do not create a separate mobile copy.
- Create `Sources/GrafttyProtocol/Keybinds/GhosttyCommandRegistry.swift` for command metadata that is UI-free.

Host transport:
- Modify `Sources/GrafttyKit/Web/WebServer.swift` to expose `GET /ghostty-keybindings`.
- Modify `Sources/Graftty/Web/WebServerController.swift` to accept a keybinding provider.
- Modify `Sources/Graftty/GrafttyApp.swift` startup to provide `terminalManager.keybindBridge.allChords`.
- Add host-side tests under existing `Tests/GrafttyKitTests/Web/` WebServer ownership tests unless a more specific route harness already exists elsewhere.

Mobile fetch/cache:
- Create `Sources/GrafttyMobileKit/Session/GhosttyKeybindingsFetcher.swift`.
- Add tests to `Tests/GrafttyMobileKitTests/Session/GhosttyKeybindingsFetcherTests.swift` and ensure the file is added to `Apps/GrafttyMobile/GrafttyMobile.xcodeproj/project.pbxproj` if needed.
- Refetch keybindings on selected-host change and on the existing mobile host-config refresh path so iPad command shortcuts rebuild when the host Ghostty config changes.

iPad execution:
- Replace `Sources/GrafttyMobileKit/App/MobileWorktreeNavFocusedValues.swift` with a broader `MobileGhosttyCommandFocusedValues.swift`, or extend it if that is the smaller diff.
- Modify `Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift` to render command buttons from the shared registry and fetched chords.
- Modify `Sources/Graftty/GrafttyApp.swift` so Mac command rendering also consumes `GhosttyCommandRegistry` rather than maintaining an independent action list.
- Modify `Sources/GrafttyMobileKit/App/IPadRootLayout.swift` / `IPadDetailColumn` to publish an iPad command executor and execute split, close, pane focus, pane next/previous, and worktree next/previous.
- Create `Sources/GrafttyMobileKit/UI/PaneLayoutNavigation.swift` for `PaneLayoutNode` directional and tree-order focus helpers.
- Add tests to `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift` and a new `Tests/GrafttyMobileKitTests/UI/PaneLayoutNavigationTests.swift` if the Xcode project includes it; otherwise put iOS simulator tests in an existing Xcode-registered file.

Specs:
- Add `@spec IPAD-9.x` markers for host-configured iPad Ghostty commands.
- Regenerate `SPECS.md`.

---

### Task 1: Move Pure Keybinding Model To GrafttyProtocol

**Files:**
- Move/create: `Sources/GrafttyProtocol/Keybinds/GhosttyAction.swift`
- Move/create: `Sources/GrafttyProtocol/Keybinds/ShortcutChord.swift`
- Move/create: `Sources/GrafttyProtocol/Keybinds/GhosttyKeybindBridge.swift`
- Delete or empty after move: `Sources/GrafttyKit/Keybinds/GhosttyAction.swift`
- Delete or empty after move: `Sources/GrafttyKit/Keybinds/ShortcutChord.swift`
- Delete or empty after move: `Sources/GrafttyKit/Keybinds/GhosttyKeybindBridge.swift`
- Move tests: `Tests/GrafttyProtocolTests/Keybinds/GhosttyActionTests.swift`
- Move tests: `Tests/GrafttyProtocolTests/Keybinds/ShortcutChordTests.swift`
- Move tests: `Tests/GrafttyProtocolTests/Keybinds/GhosttyKeybindBridgeTests.swift`
- Modify imports in Mac files/tests that currently rely on `GrafttyKit` for these types.

- [ ] **Step 1: Write/move failing protocol-level tests**

Move the existing tests from `Tests/GrafttyKitTests/Keybinds/` to `Tests/GrafttyProtocolTests/Keybinds/` and change imports:

```swift
import Testing
@testable import GrafttyProtocol
```

Keep the assertions identical so the behavior contract does not drift.

- [ ] **Step 2: Run tests to verify the missing types fail in GrafttyProtocol**

Run:

```bash
swift test --filter GhosttyActionTests
swift test --filter ShortcutChordTests
swift test --filter GhosttyKeybindBridgeTests
```

Expected: compile failure because `GhosttyAction`, `ShortcutChord`, and `GhosttyKeybindBridge` are not in `GrafttyProtocol` yet.

- [ ] **Step 3: Move the pure types**

Move the three pure files into `Sources/GrafttyProtocol/Keybinds/`. These files must import only `Foundation` or nothing. `GhosttyKeybindBridge` should also gain a snapshot accessor used by the web endpoint:

```swift
public var allChords: [GhosttyAction: ShortcutChord] { chords }
```

- [ ] **Step 4: Update imports**

Update Mac files such as `Sources/Graftty/Terminal/KeyboardShortcutFromChord.swift`, `Sources/Graftty/Terminal/GhosttyTriggerAdapter.swift`, and any affected tests to import `GrafttyProtocol` for keybinding types.

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter GhosttyActionTests
swift test --filter ShortcutChordTests
swift test --filter GhosttyKeybindBridgeTests
swift test --filter GhosttyTriggerAdapterTests
```

Expected: pass. If `GhosttyTriggerAdapterTests` does not exist, run the closest existing keybind/terminal test filter and note it in the summary.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyProtocol Sources/GrafttyKit/Keybinds Tests/GrafttyProtocolTests Tests/GrafttyKitTests Sources/Graftty
git commit -m "refactor: share ghostty keybinding model"
```

---

### Task 2: Add Shared Command Registry And SwiftUI Shortcut Conversion

**Files:**
- Modify: `Package.swift`
- Create: `Sources/GrafttyProtocol/Keybinds/GhosttyCommandRegistry.swift`
- Create: `Tests/GrafttyProtocolTests/Keybinds/GhosttyCommandRegistryTests.swift`
- Create: `Sources/GrafttyCommandUI/KeyboardShortcutFromChord.swift`
- Create: `Tests/GrafttyCommandUITests/KeyboardShortcutFromChordTests.swift` if Swift Testing can compare enough behavior; otherwise keep converter coverage in an iOS/macOS app-level test seam.
- Delete or reduce to wrapper: `Sources/Graftty/Terminal/KeyboardShortcutFromChord.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift` or a new Xcode-registered test file.

- [ ] **Step 1: Write failing registry tests**

Add tests that assert:

```swift
#expect(GhosttyCommandRegistry.allActions.map(\.action) == GhosttyAction.allCases)
#expect(GhosttyCommandRegistry.iPadSupportedActions == [
    .newSplitRight, .newSplitDown, .newSplitLeft, .newSplitUp,
    .closeSurface,
    .gotoSplitLeft, .gotoSplitRight, .gotoSplitUp, .gotoSplitDown,
    .gotoSplitPrevious, .gotoSplitNext,
    .nextTab, .previousTab,
])
#expect(GhosttyCommandRegistry.iPadSupportedActions.contains(.toggleSplitZoom) == false)
#expect(GhosttyCommandRegistry.iPadSupportedActions.contains(.equalizeSplits) == false)
#expect(GhosttyCommandRegistry.iPadSupportedActions.contains(.reloadConfig) == false)
#expect(GhosttyCommandRegistry.iPadSupportedActions.contains(.openConfig) == false)
```

- [ ] **Step 2: Run registry test to verify failure**

Run:

```bash
swift test --filter GhosttyCommandRegistryTests
```

Expected: compile failure because the registry does not exist.

- [ ] **Step 3: Implement registry**

Implement a UI-free registry with command kinds:

```swift
public enum GhosttyCommandKind: Sendable, Hashable {
    case split(GhosttySplitDirection)
    case closePane
    case focusPane(GhosttyPaneFocusDirection)
    case focusPaneByOrder(forward: Bool)
    case navigateWorktree(forward: Bool)
    case unsupported
}

public enum GhosttySplitDirection: String, Sendable, Hashable, Codable {
    case left, right, up, down
}

public enum GhosttyPaneFocusDirection: String, Sendable, Hashable, Codable {
    case left, right, up, down
}
```

Keep these enums in `GrafttyProtocol`. Map them to Mac split/focus types and mobile `PaneControlRequest.SplitDirection` at the platform boundary. Do not reference app-local focus types from the protocol target.

- [ ] **Step 4: Move shortcut conversion into the shared target**

Add `GrafttyCommandUI` in `Package.swift`:

```swift
.target(
    name: "GrafttyCommandUI",
    dependencies: ["GrafttyProtocol"],
    swiftSettings: strictWarnings
)
```

Also add `GrafttyCommandUITests` as a test target if tests live under `Tests/GrafttyCommandUITests`. Add `GrafttyCommandUI` as a dependency of `Graftty` and `GrafttyMobileKit`. Move the existing Mac converter implementation from `Sources/Graftty/Terminal/KeyboardShortcutFromChord.swift` to `Sources/GrafttyCommandUI/KeyboardShortcutFromChord.swift`, make the type public, and update imports at call sites to `import GrafttyCommandUI`.

- [ ] **Step 5: Write failing shortcut conversion tests for shared/mobile use**

Add iOS simulator tests for mobile `KeyboardShortcutFromChord.shortcut(from:)` covering at least:

```swift
#expect(KeyboardShortcutFromChord.shortcut(from: .init(key: "tab", modifiers: [.control])) != nil)
#expect(KeyboardShortcutFromChord.shortcut(from: .init(key: "arrowleft", modifiers: [.command, .option])) != nil)
#expect(KeyboardShortcutFromChord.shortcut(from: .init(key: "f13", modifiers: [.command])) == nil)
```

If SwiftUI `KeyboardShortcut` does not expose comparable fields for direct assertion, expose UI-free helpers on `KeyboardShortcutFromChord` with `internal` access and `@testable import GrafttyCommandUI`, or assert nil/non-nil plus action routing at the command-rendering seam.

Run:

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests
```

Expected: compile failure because the mobile converter does not exist or is not visible.

- [ ] **Step 6: Make Mac command rendering consume the shared registry**

Replace the hardcoded Mac command action lists in `Sources/Graftty/GrafttyApp.swift` with iteration over `GhosttyCommandRegistry` entries where appropriate. Preserve the existing menu grouping and execution closures, but the set of actions and labels must come from registry metadata so Mac and iPad cannot drift.

- [ ] **Step 7: Run tests**

Run:

```bash
swift test --filter GhosttyCommandRegistryTests
swift test --filter KeyboardShortcutFromChordTests
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests
```

Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/GrafttyProtocol Sources/GrafttyCommandUI Sources/GrafttyMobileKit Tests/GrafttyProtocolTests Tests/GrafttyCommandUITests Tests/GrafttyMobileKitTests Sources/Graftty
git commit -m "feat: add shared ghostty command registry"
```

---

### Task 3: Expose Host-Resolved Keybindings Over Web Access

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebServer.swift`
- Modify: `Sources/Graftty/Web/WebServerController.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: existing web server tests under `Tests/GrafttyKitTests/Web/` or create `Tests/GrafttyKitTests/Web/GhosttyKeybindingsEndpointTests.swift`.

- [ ] **Step 1: Write failing WebServer endpoint test**

Add a test that starts/configures `WebServer` or invokes its route test harness and asserts `GET /ghostty-keybindings` returns JSON like:

```json
{
  "bindings": {
    "new_split:right": { "key": "d", "modifiers": 8 },
    "next_tab": { "key": "tab", "modifiers": 2 }
  }
}
```

Use `ShortcutModifiers.rawValue` for JSON. If the existing test harness prefers decoding, define:

```swift
struct GhosttyKeybindingsResponse: Codable, Equatable {
    var bindings: [String: ShortcutChord]
}
```

- [ ] **Step 2: Run endpoint test to verify failure**

Run the specific test filter. Expected: 404 or compile failure because no provider/route exists.

- [ ] **Step 3: Add provider to WebServer.Config**

Add:

```swift
public let ghosttyKeybindingsProvider: @Sendable () async -> [GhosttyAction: ShortcutChord]
```

Default to `{ [:] }`.

- [ ] **Step 4: Add route**

In `HTTPHandler.serveStatic`, add `GET /ghostty-keybindings` near `/ghostty-config`. Respond JSON with string raw values:

```swift
let payload = GhosttyKeybindingsResponse(
    bindings: Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
)
```

Do not call `respondEncodable(context:items:)`, which is array-specific. Either add a single-object helper:

```swift
private static func respondEncodable<T: Encodable>(
    context: ChannelHandlerContext,
    item: T,
    status: HTTPResponseStatus = .ok
)
```

or encode `payload` directly with `JSONEncoder` and call the existing raw response helper. Add the route test before implementation so the exact helper shape is validated.

- [ ] **Step 5: Wire WebServerController**

Add `ghosttyKeybindingsProvider` storage, `setGhosttyKeybindingsProvider`, and pass it into `WebServer.Config` during `reconcile()`.

- [ ] **Step 6: Wire GrafttyApp**

In `startup()`, install:

```swift
webController.setGhosttyKeybindingsProvider { [tm = terminalManager] in
    await MainActor.run { tm.keybindBridge.allChords }
}
```

- [ ] **Step 7: Run tests**

Run the new endpoint test and a focused build:

```bash
swift test --filter GhosttyKeybindings
swift test --filter GhosttyKeybindBridgeTests
```

Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/Web/WebServer.swift Sources/Graftty/Web/WebServerController.swift Sources/Graftty/GrafttyApp.swift Tests/GrafttyKitTests
git commit -m "feat: serve resolved ghostty keybindings"
```

---

### Task 4: Fetch And Cache Host Keybindings On Mobile

**Files:**
- Create: `Sources/GrafttyMobileKit/Session/GhosttyKeybindingsFetcher.swift`
- Test: `Tests/GrafttyMobileKitTests/Session/GhosttyKeybindingsFetcherTests.swift`
- Modify if needed: `Apps/GrafttyMobile/GrafttyMobile.xcodeproj/project.pbxproj`
- Modify: `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`

- [ ] **Step 1: Write failing fetcher tests**

Cover:

```swift
// 2xx valid JSON decodes to GhosttyKeybindBridge
#expect(bridge[.newSplitRight] == ShortcutChord(key: "d", modifiers: [.command]))

// non-2xx returns empty bridge
#expect(bridge[.newSplitRight] == nil)

// malformed JSON returns empty bridge
#expect(bridge[.newSplitRight] == nil)
```

Follow existing URLProtocol test style in `GhosttyConfigFetcherTests` or nearby fetcher tests. Also add a refresh-seam test if an existing mobile config-refresh type is testable: when host config/theme refresh completes, keybindings are refetched and the exposed bridge changes from the old chord to the new chord.

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/GhosttyKeybindingsFetcherTests
```

Expected: compile failure because the fetcher does not exist.

- [ ] **Step 3: Implement fetcher**

Implement:

```swift
public enum GhosttyKeybindingsFetcher {
    @MainActor public static func fetch(baseURL: URL) async -> GhosttyKeybindBridge
    static func fetchUncached(baseURL: URL, session: URLSession = .shared) async -> GhosttyKeybindBridge
}
```

Fetch `GET <baseURL>/ghostty-keybindings`, decode `bindings: [String: ShortcutChord]`, and initialize `GhosttyKeybindBridge` by matching `GhosttyAction.rawValue`. Non-2xx/malformed responses return an empty bridge.

- [ ] **Step 4: Add IPadRootLayout state**

Add:

```swift
@State private var keybindBridge = GhosttyKeybindBridge { _ in nil }
```

Fetch it in the existing `selectedHost?.id` task or a separate task:

```swift
keybindBridge = await GhosttyKeybindingsFetcher.fetch(baseURL: host.baseURL)
```

Also refetch it from the same path that refreshes host Ghostty config/theme state on mobile. If that path currently lives only in `IPadRootLayout`, factor a small `refreshHostPresentationState(for:)` helper that updates both config/theme and keybindings together. The command scene context must be rebuilt when `keybindBridge` changes; stale shortcuts after host config reload are a bug.

- [ ] **Step 5: Run tests**

Run:

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/GhosttyKeybindingsFetcherTests -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/GhosttyKeybindingsFetcher.swift Sources/GrafttyMobileKit/App/IPadRootLayout.swift Tests/GrafttyMobileKitTests/Session/GhosttyKeybindingsFetcherTests.swift Apps/GrafttyMobile/GrafttyMobile.xcodeproj/project.pbxproj
git commit -m "feat(ipad): fetch host ghostty keybindings"
```

---

### Task 5: Implement iPad Command Routing For Supported Ghostty Actions

**Files:**
- Modify/create: `Sources/GrafttyMobileKit/App/MobileGhosttyCommandFocusedValues.swift`
- Modify: `Sources/GrafttyMobileKit/App/MobileWorktreeNavFocusedValues.swift` or delete after replacement.
- Modify: `Sources/GrafttyMobileKit/App/GrafttyMobileApp.swift`
- Modify: `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`
- Modify: `Sources/GrafttyMobileKit/App/IPadDetailColumn.swift` if split/close helpers need to move out of private scope.
- Create: `Sources/GrafttyMobileKit/UI/PaneLayoutNavigation.swift`
- Test: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`

- [ ] **Step 1: Write failing routing tests**

In an Xcode-registered iOS test file, add tests for pure/static seams:

```swift
#expect(IPadRootLayout.commandKind(for: .newSplitRight) == .split(.right))
#expect(IPadRootLayout.commandKind(for: .newSplitDown) == .split(.down))
#expect(IPadRootLayout.commandKind(for: .closeSurface) == .closePane)
#expect(IPadRootLayout.commandKind(for: .toggleSplitZoom) == nil)
```

Add pane navigation tests for representative `PaneLayoutNode`:

```swift
let layout = PaneLayoutNode.split(direction: .horizontal, ratio: 0.5,
    left: .leaf(sessionName: "a", title: "", attentionText: nil, isBusy: false, attentionSource: nil),
    right: .split(direction: .vertical, ratio: 0.5,
        left: .leaf(sessionName: "b", title: "", attentionText: nil, isBusy: false, attentionSource: nil),
        right: .leaf(sessionName: "c", title: "", attentionText: nil, isBusy: false, attentionSource: nil)))
#expect(PaneLayoutNavigation.spatialNeighbor(in: layout, of: "a", direction: .right) == "b")
#expect(PaneLayoutNavigation.spatialNeighbor(in: layout, of: "b", direction: .down) == "c")
#expect(PaneLayoutNavigation.nextInOrder(in: layout, from: "c", forward: true) == "a")
#expect(PaneLayoutNavigation.spatialNeighbor(in: layout, of: "a", direction: .left) == nil)
#expect(PaneLayoutNavigation.nextInOrder(in: .leaf(sessionName: "only", title: "", attentionText: nil, isBusy: false, attentionSource: nil), from: "only", forward: true) == nil)
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests
```

Expected: compile failure because command routing/pane navigation helpers do not exist.

- [ ] **Step 3: Implement pane layout navigation**

Implement `PaneLayoutNavigation` by matching Mac `SplitTree.spatialNeighbor` semantics:

- Directional focus walks from focused leaf up to the nearest ancestor whose split axis matches the requested direction and whose source side contains the leaf.
- Descend into the opposite subtree's near edge.
- No directional wrapping.
- Previous/next uses `PaneLayoutNode.leaves` order with wraparound.

- [ ] **Step 4: Implement command executor seam**

Define focused scene command context:

```swift
struct MobileGhosttyCommandContext {
    let keybindBridge: GhosttyKeybindBridge
    let perform: (GhosttyAction) -> Void
    let isEnabled: (GhosttyAction) -> Bool
}
```

Publish it via `focusedSceneValue` from `IPadRootLayout`. This is required because `GrafttyMobileApp.commands` cannot directly read `IPadRootLayout` state. The context must include both the fetched keybinding bridge and the executor/enabled state.

In `IPadRootLayout`, map only supported actions using the shared registry. Unsupported actions return nil and do not install shortcuts.

- [ ] **Step 5: Implement command buttons from fetched chords**

In `GrafttyMobileApp.commands`, render buttons for `GhosttyCommandRegistry.iPadSupportedActions`. For each action:

- Look up the currently focused command action.
- Look up the action chord from the current iPad bridge.
- Convert with `KeyboardShortcutFromChord`.
- Omit commands with nil shortcuts.
- Disable commands when focused action is nil.

Add a focused command-rendering test seam, or a small pure filter helper, proving that a registry action with a missing or untranslatable chord is omitted rather than installed with a fallback shortcut.

Do not return to invisible overlay-only buttons.

- [ ] **Step 6: Wire supported operations**

For each action:

- Split: call existing pane-control split path with current `focusedPaneId`.
- Close: call `paneControlClient.close(target:)`; on `.ok`, call `onPaneTreeChanged()`.
- Directional pane focus: map `GhosttyPaneFocusDirection` to `PaneLayoutNavigation.Direction`, update `focusedPaneId` using `PaneLayoutNavigation.spatialNeighbor`, then `requestActiveTerminal()`.
- Previous/next pane: update `focusedPaneId` using `PaneLayoutNavigation.nextInOrder`, then `requestActiveTerminal()`.
- Next/previous worktree: reuse `navigateWorktree(forward:)`.

- [ ] **Step 7: Run tests**

Run:

```bash
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests -only-testing:GrafttyMobileKitTests/WorktreeListContentTests
```

Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyMobileKit Tests/GrafttyMobileKitTests Apps/GrafttyMobile/GrafttyMobile.xcodeproj/project.pbxproj
git commit -m "feat(ipad): route ghostty keyboard commands"
```

---

### Task 6: Specs, Integration Verification, And PR Update

**Files:**
- Modify: tests with `@spec` markers for new behavior.
- Modify: `SPECS.md`
- No feature-code edits unless verification finds a defect.

- [ ] **Step 1: Add final spec markers**

Add or verify EARS-style `@spec` markers for:

- iPad fetches host-resolved Ghostty keybindings.
- iPad registers only supported translated Ghostty action chords at scene-command precedence.
- iPad split/close/focus/worktree commands route to the specified behavior.
- Deferred commands are not registered on iPad.

- [ ] **Step 2: Regenerate specs**

Run:

```bash
scripts/generate-specs.py
scripts/generate-specs.py --check
git diff --check
```

Expected: pass.

- [ ] **Step 3: Run focused verification**

Run:

```bash
swift test --filter GhosttyActionTests
swift test --filter GhosttyKeybindBridgeTests
swift test --filter GhosttyCommandRegistryTests
swift test --filter KeyboardShortcutFromChordTests
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test -only-testing:GrafttyMobileKitTests/GhosttyKeybindingsFetcherTests -only-testing:GrafttyMobileKitTests/IPadRootLayoutSelectionTests -only-testing:GrafttyMobileKitTests/WorktreeListContentTests
xcodebuild -quiet -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -configuration Debug build
```

Expected: pass. Existing warning noise is acceptable only if command exit status is 0.

- [ ] **Step 4: Commit verification/spec updates**

```bash
git add SPECS.md Tests Sources Apps
git commit -m "docs: update specs for ipad ghostty commands"
```

Skip this commit if there are no changes after verification.

- [ ] **Step 5: Push branch**

```bash
git status -sb
git push
```

Expected: branch is clean and PR #247 is updated.
