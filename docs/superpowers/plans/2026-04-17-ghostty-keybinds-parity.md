# Ghostty Keybind Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every Ghostty apprt action in the user's config to the matching Espalier pane operation, including two new pane-layout features (zoom and programmatic split resize). Espalier never hardcodes chords; menu shortcut hints are derived from Ghostty's config at startup.

**Architecture:** Pure-Swift keybind types + bridge in `EspalierKit` (testable without GhosttyKit). Thin GhosttyKit-aware adapter + SwiftUI translator in the `Espalier` app target. `TerminalManager.handleAction` grows cases for the new actions. `SplitTree` gets `zoomed`, `resizing`, `equalizing`, `togglingZoom`. Menu `.commands` block pulls shortcuts from the bridge instead of hardcoded strings.

**Tech Stack:** Swift 5.10, Swift Testing, SwiftUI, GhosttyKit (libghostty-spm), EspalierKit.

Spec: `docs/superpowers/specs/2026-04-17-ghostty-keybinds-parity-design.md`

---

## File Structure

### Created

- `Sources/EspalierKit/Keybinds/ShortcutChord.swift` — pure-Swift `ShortcutChord` struct and `ShortcutKey` / `ShortcutModifiers`.
- `Sources/EspalierKit/Keybinds/GhosttyAction.swift` — enum of actions Espalier cares about, with raw-value action names matching Ghostty's config syntax.
- `Sources/EspalierKit/Keybinds/GhosttyKeybindBridge.swift` — resolver-driven action-to-chord map. No GhosttyKit, no SwiftUI.
- `Sources/EspalierKit/Model/ResizeDirection.swift` — enum used by `SplitTree.resizing`.
- `Sources/Espalier/Terminal/GhosttyTriggerAdapter.swift` — `ghostty_input_trigger_s → ShortcutChord?`.
- `Sources/Espalier/Terminal/KeyboardShortcutFromChord.swift` — `ShortcutChord → SwiftUI.KeyboardShortcut?`.
- `Tests/EspalierKitTests/Keybinds/ShortcutChordTests.swift`
- `Tests/EspalierKitTests/Keybinds/GhosttyKeybindBridgeTests.swift`
- `Tests/EspalierKitTests/Keybinds/GhosttyActionTests.swift`
- `Tests/EspalierKitTests/Model/SplitTreeZoomTests.swift`
- `Tests/EspalierKitTests/Model/SplitTreeResizeTests.swift`
- `Tests/EspalierKitTests/Model/SplitTreeEqualizeTests.swift`

### Modified

- `Sources/EspalierKit/Model/SplitTree.swift` — add `zoomed`, update `inserting/insertingBefore/removing` to enforce invariants, add `togglingZoom`, `resizing`, `equalizing`.
- `Sources/Espalier/Terminal/TerminalManager.swift` — new callbacks (`onResizeSplit`, `onEqualizeSplits`, `onToggleZoom`, `onReloadConfig`), new `handleAction` cases, `keybindBridge` property.
- `Sources/Espalier/EspalierApp.swift` — wire callbacks, rebuild `.commands` using bridge shortcuts.
- `Sources/Espalier/Views/SplitContainerView.swift` — render only the zoomed leaf when `tree.zoomed != nil`.
- `SPECS.md` — new §14 per spec doc.

---

## Task 1: Add `zoomed` field to `SplitTree`

**Files:**
- Modify: `Sources/EspalierKit/Model/SplitTree.swift`
- Test: `Tests/EspalierKitTests/Model/SplitTreeZoomTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/EspalierKitTests/Model/SplitTreeZoomTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("SplitTree — zoom state")
struct SplitTreeZoomTests {
    @Test func newTreeHasNoZoom() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id))
        #expect(tree.zoomed == nil)
    }

    @Test func initWithZoomedSetsZoomedField() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id), zoomed: id)
        #expect(tree.zoomed == id)
    }

    @Test func codableRoundTripPreservesZoom() throws {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id), zoomed: id)
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)
        #expect(decoded.zoomed == id)
    }

    @Test func codableBackwardsCompatibleWithLegacyPayload() throws {
        // Payloads written before this feature have no `zoomed` key.
        let legacy = #"{"root":{"leaf":{"_0":{"id":"\#(UUID().uuidString)"}}}}"#
        let decoded = try JSONDecoder().decode(
            SplitTree.self,
            from: legacy.data(using: .utf8)!
        )
        #expect(decoded.zoomed == nil)
    }
}
```

- [ ] **Step 2: Run, verify fail**

```bash
swift test --filter SplitTreeZoomTests
```

Expected: FAIL — `zoomed` is not a member of `SplitTree`.

- [ ] **Step 3: Add field to `SplitTree`**

Edit `Sources/EspalierKit/Model/SplitTree.swift`. Replace the existing struct declaration with:

```swift
public struct SplitTree: Codable, Sendable, Equatable {
    public let root: Node?

    /// The leaf that is currently zoomed — rendered alone, filling the
    /// surface, with siblings hidden (but alive). `nil` means normal
    /// split-tree rendering.
    ///
    /// Invariants, ported from upstream Ghostty's `SplitTree.swift:9-11`:
    /// - `inserting(...)` clears zoom (splitting from a zoomed state
    ///   always unzooms).
    /// - `removing(target)` clears zoom iff `target == zoomed`.
    /// - `resizing(...)` clears zoom.
    public let zoomed: TerminalID?

    public init(root: Node?, zoomed: TerminalID? = nil) {
        self.root = root
        self.zoomed = zoomed
    }
    ...
}
```

Codable synthesis handles the new field; the backwards-compat test covers the missing-key case.

- [ ] **Step 4: Run tests**

```bash
swift test --filter SplitTreeZoomTests
swift test --filter SplitTreeTests  # existing tests must still pass
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Model/SplitTree.swift Tests/EspalierKitTests/Model/SplitTreeZoomTests.swift
git commit -m "feat(kit): SplitTree gains zoomed: TerminalID? field"
```

---

## Task 2: Update mutations to enforce zoom invariants

**Files:**
- Modify: `Sources/EspalierKit/Model/SplitTree.swift`
- Test: `Tests/EspalierKitTests/Model/SplitTreeZoomTests.swift` (extend)

- [ ] **Step 1: Add failing tests**

Append to `SplitTreeZoomTests.swift`:

```swift
@Test func insertingUnzooms() {
    let a = TerminalID(); let b = TerminalID()
    let tree = SplitTree(root: .leaf(a), zoomed: a)
    let next = tree.inserting(b, at: a, direction: .horizontal)
    #expect(next.zoomed == nil, "insert must clear zoom")
}

@Test func insertingBeforeUnzooms() {
    let a = TerminalID(); let b = TerminalID()
    let tree = SplitTree(root: .leaf(a), zoomed: a)
    let next = tree.insertingBefore(b, at: a, direction: .horizontal)
    #expect(next.zoomed == nil)
}

@Test func removingZoomedLeafAutoUnzooms() {
    let a = TerminalID(); let b = TerminalID()
    let tree = SplitTree(root: .leaf(a), zoomed: a)
        .inserting(b, at: a, direction: .horizontal)
        .withZoom(a)    // re-zoom after insert cleared it
    let next = tree.removing(a)
    #expect(next.zoomed == nil)
}

@Test func removingSiblingPreservesZoomOnSurvivor() {
    let a = TerminalID(); let b = TerminalID()
    let tree = SplitTree(root: .leaf(a))
        .inserting(b, at: a, direction: .horizontal)
        .withZoom(a)
    let next = tree.removing(b)
    #expect(next.zoomed == a)
}
```

`withZoom(_:)` is a small test-friendly convenience on `SplitTree` that returns a new tree with `zoomed` set (we also ship it so non-test callers have an ergonomic way to set zoom). Add it to the public API.

- [ ] **Step 2: Run, verify fail**

```bash
swift test --filter SplitTreeZoomTests
```

Expected: FAIL — `withZoom` not defined; mutations don't yet touch `zoomed`.

- [ ] **Step 3: Implement**

Edit `Sources/EspalierKit/Model/SplitTree.swift`:

```swift
public func withZoom(_ id: TerminalID?) -> SplitTree {
    SplitTree(root: root, zoomed: id)
}

public func inserting(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree {
    guard let root else { return self }
    // Invariant: inserting clears zoom.
    return SplitTree(root: root.inserting(newLeaf, at: target, direction: direction), zoomed: nil)
}

public func insertingBefore(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree {
    guard let root else { return self }
    return SplitTree(root: root.insertingBefore(newLeaf, at: target, direction: direction), zoomed: nil)
}

public func removing(_ target: TerminalID) -> SplitTree {
    guard let root else { return self }
    // Invariant: removing the zoomed leaf auto-unzooms; removing others
    // preserves zoom on the survivor.
    let newZoomed: TerminalID? = (zoomed == target) ? nil : zoomed
    return SplitTree(root: root.removing(target), zoomed: newZoomed)
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter SplitTreeZoomTests
swift test --filter SplitTreeTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Model/SplitTree.swift Tests/EspalierKitTests/Model/SplitTreeZoomTests.swift
git commit -m "feat(kit): SplitTree mutations enforce zoom invariants"
```

---

## Task 3: Add `togglingZoom`

**Files:**
- Modify: `Sources/EspalierKit/Model/SplitTree.swift`
- Test: `Tests/EspalierKitTests/Model/SplitTreeZoomTests.swift` (extend)

- [ ] **Step 1: Add failing tests**

Append:

```swift
@Test func togglingZoomOnSplitLeafZoomsThatLeaf() {
    let a = TerminalID(); let b = TerminalID()
    let tree = SplitTree(root: .leaf(a))
        .inserting(b, at: a, direction: .horizontal)
    let next = tree.togglingZoom(at: a)
    #expect(next.zoomed == a)
}

@Test func togglingZoomOnCurrentlyZoomedLeafUnzooms() {
    let a = TerminalID(); let b = TerminalID()
    let tree = SplitTree(root: .leaf(a))
        .inserting(b, at: a, direction: .horizontal)
        .withZoom(a)
    let next = tree.togglingZoom(at: a)
    #expect(next.zoomed == nil)
}

@Test func togglingZoomOnLoneLeafIsNoOp() {
    let a = TerminalID()
    let tree = SplitTree(root: .leaf(a))
    let next = tree.togglingZoom(at: a)
    #expect(next.zoomed == nil)
}

@Test func togglingZoomOnUnknownLeafIsNoOp() {
    let a = TerminalID(); let b = TerminalID(); let c = TerminalID()
    let tree = SplitTree(root: .leaf(a))
        .inserting(b, at: a, direction: .horizontal)
    let next = tree.togglingZoom(at: c)
    #expect(next.zoomed == nil)
}
```

- [ ] **Step 2: Run, verify fail**

```bash
swift test --filter SplitTreeZoomTests
```

Expected: FAIL — `togglingZoom` not defined.

- [ ] **Step 3: Implement**

```swift
public func togglingZoom(at leaf: TerminalID) -> SplitTree {
    guard allLeaves.contains(leaf), leafCount > 1 else {
        return self  // lone leaf or unknown id → no-op
    }
    return SplitTree(root: root, zoomed: (zoomed == leaf) ? nil : leaf)
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter SplitTreeZoomTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Model/SplitTree.swift Tests/EspalierKitTests/Model/SplitTreeZoomTests.swift
git commit -m "feat(kit): SplitTree.togglingZoom(at:)"
```

---

## Task 4: `ResizeDirection` + `SplitTree.resizing`

**Files:**
- Create: `Sources/EspalierKit/Model/ResizeDirection.swift`
- Modify: `Sources/EspalierKit/Model/SplitTree.swift`
- Create: `Tests/EspalierKitTests/Model/SplitTreeResizeTests.swift`

- [ ] **Step 1: Create the enum**

`Sources/EspalierKit/Model/ResizeDirection.swift`:

```swift
import Foundation

/// Direction for `SplitTree.resizing(target:direction:pixels:ancestorBounds:)`.
/// Mirrors Ghostty's `ghostty_action_resize_split_direction_e`:
/// UP / DOWN target vertical ancestors (the divider is horizontal);
/// LEFT / RIGHT target horizontal ancestors (the divider is vertical).
public enum ResizeDirection: Sendable {
    case up, down, left, right

    /// The split-tree orientation whose ancestor this direction resizes.
    public var orientation: SplitDirection {
        switch self {
        case .up, .down:    return .vertical
        case .left, .right: return .horizontal
        }
    }

    /// Sign carried by this direction: +1 grows the right/bottom child,
    /// -1 grows the left/top child. Caller multiplies the pixel amount
    /// by this when computing the ratio delta.
    public var sign: Double {
        switch self {
        case .right, .down: return +1
        case .left, .up:    return -1
        }
    }
}
```

- [ ] **Step 2: Write failing tests**

`Tests/EspalierKitTests/Model/SplitTreeResizeTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import EspalierKit

@Suite("SplitTree — resizing")
struct SplitTreeResizeTests {
    private func horizontalTree() -> (SplitTree, TerminalID, TerminalID) {
        // a | b, 50/50 horizontal split (left / right)
        let a = TerminalID(); let b = TerminalID()
        let tree = SplitTree(root: .leaf(a))
            .inserting(b, at: a, direction: .horizontal)
        return (tree, a, b)
    }

    @Test func resizeRightGrowsLeftChild() throws {
        let (tree, a, _) = horizontalTree()
        // Current ratio is 0.5; 100px right on a 1000px-wide split → +0.1.
        let next = try tree.resizing(
            target: a,
            direction: .right,
            pixels: 100,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        let ratio = next.ratioOfSplit(containing: a)
        #expect(abs(ratio - 0.6) < 1e-6, "expected 0.6, got \(ratio)")
    }

    @Test func resizeClampsAtLowerBound() throws {
        let (tree, a, _) = horizontalTree()
        let next = try tree.resizing(
            target: a,
            direction: .left,
            pixels: 10_000,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        #expect(abs(next.ratioOfSplit(containing: a) - 0.1) < 1e-6)
    }

    @Test func resizeClampsAtUpperBound() throws {
        let (tree, a, _) = horizontalTree()
        let next = try tree.resizing(
            target: a,
            direction: .right,
            pixels: 10_000,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        #expect(abs(next.ratioOfSplit(containing: a) - 0.9) < 1e-6)
    }

    @Test func resizeThrowsWhenNoMatchingOrientationAncestor() throws {
        let (tree, a, _) = horizontalTree()
        #expect(throws: SplitTreeError.noMatchingAncestor) {
            try tree.resizing(
                target: a,
                direction: .up,     // needs vertical ancestor; tree has only horizontal
                pixels: 50,
                ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
            )
        }
    }

    @Test func resizeClearsZoom() throws {
        let (tree, a, _) = horizontalTree()
        let zoomed = tree.withZoom(a)
        let next = try zoomed.resizing(
            target: a,
            direction: .right,
            pixels: 10,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        #expect(next.zoomed == nil)
    }
}
```

- [ ] **Step 3: Run, verify fail**

```bash
swift test --filter SplitTreeResizeTests
```

Expected: FAIL — `resizing`, `SplitTreeError`, `ratioOfSplit(containing:)` missing.

- [ ] **Step 4: Implement**

Append to `SplitTree.swift`:

```swift
public enum SplitTreeError: Error, Equatable {
    case noMatchingAncestor
}

/// Resize the nearest ancestor split of `target` whose orientation matches
/// `direction`, by `pixels` against the given `ancestorBounds`.
///
/// Ratio is clamped to [0.1, 0.9]; returned tree has `zoomed: nil`.
/// Throws `SplitTreeError.noMatchingAncestor` when no such ancestor
/// exists (matches Ghostty upstream).
public func resizing(
    target: TerminalID,
    direction: ResizeDirection,
    pixels: UInt16,
    ancestorBounds: CGRect
) throws -> SplitTree {
    guard let root else { throw SplitTreeError.noMatchingAncestor }
    let orientation = direction.orientation
    let axisSize = orientation == .horizontal ? ancestorBounds.width : ancestorBounds.height
    guard axisSize > 0 else { throw SplitTreeError.noMatchingAncestor }
    let delta = direction.sign * (Double(pixels) / Double(axisSize))
    let newRoot = try root.resizingAncestor(
        of: target,
        orientation: orientation,
        delta: delta
    )
    return SplitTree(root: newRoot, zoomed: nil)
}

/// Returns the ratio of the innermost split containing `leaf`. Used by tests
/// and by the split-container view's resize call site.
public func ratioOfSplit(containing leaf: TerminalID) -> Double {
    root?.ratioOfSplit(containing: leaf) ?? 0
}
```

And on `SplitTree.Node` (indirect enum):

```swift
func resizingAncestor(
    of leaf: TerminalID,
    orientation: SplitDirection,
    delta: Double
) throws -> Node {
    switch self {
    case .leaf:
        throw SplitTree.SplitTreeError.noMatchingAncestor
    case .split(let split):
        // Does this split contain the leaf? If so AND orientation matches,
        // resize here. Otherwise recurse into whichever child contains it.
        let leftContains = split.left.allLeaves.contains(leaf)
        let rightContains = split.right.allLeaves.contains(leaf)
        guard leftContains || rightContains else {
            throw SplitTree.SplitTreeError.noMatchingAncestor
        }
        if split.direction == orientation {
            let newRatio = min(0.9, max(0.1, split.ratio + delta))
            return .split(split.withRatio(newRatio))
        }
        // Recurse; if no matching ancestor found downstream, bubble up.
        if leftContains {
            let newLeft = try split.left.resizingAncestor(of: leaf, orientation: orientation, delta: delta)
            return .split(SplitTree.Node.Split(direction: split.direction, ratio: split.ratio, left: newLeft, right: split.right))
        } else {
            let newRight = try split.right.resizingAncestor(of: leaf, orientation: orientation, delta: delta)
            return .split(SplitTree.Node.Split(direction: split.direction, ratio: split.ratio, left: split.left, right: newRight))
        }
    }
}

func ratioOfSplit(containing leaf: TerminalID) -> Double {
    switch self {
    case .leaf:
        return 0
    case .split(let split):
        if case .leaf(let id) = split.left, id == leaf { return split.ratio }
        if case .leaf(let id) = split.right, id == leaf { return split.ratio }
        return split.left.ratioOfSplit(containing: leaf) + split.right.ratioOfSplit(containing: leaf)
    }
}
```

(The `ratioOfSplit` recursion returns the ratio of whichever ancestor leaf-contains, relying on leaf uniqueness. `+` is safe because only one recursive branch has the leaf and the other contributes 0.)

- [ ] **Step 5: Run tests**

```bash
swift test --filter SplitTreeResizeTests
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/EspalierKit/Model/ResizeDirection.swift Sources/EspalierKit/Model/SplitTree.swift Tests/EspalierKitTests/Model/SplitTreeResizeTests.swift
git commit -m "feat(kit): SplitTree.resizing + ResizeDirection + clamp at [0.1, 0.9]"
```

---

## Task 5: `SplitTree.equalizing()`

**Files:**
- Modify: `Sources/EspalierKit/Model/SplitTree.swift`
- Create: `Tests/EspalierKitTests/Model/SplitTreeEqualizeTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("SplitTree — equalizing")
struct SplitTreeEqualizeTests {
    @Test func equalizeResetsAllSplitRatiosToHalf() {
        let a = TerminalID(); let b = TerminalID(); let c = TerminalID()
        let tree = SplitTree(root: .leaf(a))
            .inserting(b, at: a, direction: .horizontal)
            .inserting(c, at: b, direction: .vertical)
        // Manually set a non-0.5 ratio (via a rebuild) — quick test-local
        // way to mess up the ratios, since normal inserts default to 0.5.
        // (In practice, drag-resize changes ratios; we simulate by going
        // through resizing.)
        let pulled = try! tree.resizing(
            target: a,
            direction: .right,
            pixels: 100,
            ancestorBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        let equalized = pulled.equalizing()
        // Every internal split has ratio 0.5.
        equalized.forEachSplit { #expect(abs($0.ratio - 0.5) < 1e-9) }
    }

    @Test func equalizeClearsZoom() {
        let a = TerminalID(); let b = TerminalID()
        let tree = SplitTree(root: .leaf(a))
            .inserting(b, at: a, direction: .horizontal)
            .withZoom(a)
        #expect(tree.equalizing().zoomed == nil)
    }
}
```

(`forEachSplit` is a test-only helper to walk splits; add as an internal extension in `EspalierKitTests` or publicize on `SplitTree` — plan publicizes to keep the test simple.)

- [ ] **Step 2: Run, verify fail**

```bash
swift test --filter SplitTreeEqualizeTests
```

Expected: FAIL.

- [ ] **Step 3: Implement**

Append to `SplitTree.swift`:

```swift
public func equalizing() -> SplitTree {
    SplitTree(root: root?.equalizing(), zoomed: nil)
}

public func forEachSplit(_ body: (Node.Split) -> Void) {
    root?.forEachSplit(body)
}
```

And on `Node`:

```swift
func equalizing() -> Node {
    switch self {
    case .leaf:
        return self
    case .split(let s):
        return .split(SplitTree.Node.Split(
            direction: s.direction,
            ratio: 0.5,
            left: s.left.equalizing(),
            right: s.right.equalizing()
        ))
    }
}

func forEachSplit(_ body: (SplitTree.Node.Split) -> Void) {
    switch self {
    case .leaf:
        return
    case .split(let s):
        body(s)
        s.left.forEachSplit(body)
        s.right.forEachSplit(body)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter SplitTreeEqualizeTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Model/SplitTree.swift Tests/EspalierKitTests/Model/SplitTreeEqualizeTests.swift
git commit -m "feat(kit): SplitTree.equalizing resets all split ratios to 0.5"
```

---

## Task 6: Pure keybind types (`ShortcutChord`, `ShortcutModifiers`, `GhosttyAction`)

**Files:**
- Create: `Sources/EspalierKit/Keybinds/ShortcutChord.swift`
- Create: `Sources/EspalierKit/Keybinds/GhosttyAction.swift`
- Create: `Tests/EspalierKitTests/Keybinds/ShortcutChordTests.swift`
- Create: `Tests/EspalierKitTests/Keybinds/GhosttyActionTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/EspalierKitTests/Keybinds/ShortcutChordTests.swift`:

```swift
import Testing
@testable import EspalierKit

@Suite("ShortcutChord")
struct ShortcutChordTests {
    @Test func modifiersOptionSetCombines() {
        let m: ShortcutModifiers = [.command, .shift]
        #expect(m.contains(.command))
        #expect(m.contains(.shift))
        #expect(!m.contains(.option))
    }

    @Test func chordEqualityIgnoresNothing() {
        let a = ShortcutChord(key: "d", modifiers: [.command])
        let b = ShortcutChord(key: "d", modifiers: [.command])
        let c = ShortcutChord(key: "d", modifiers: [.command, .shift])
        #expect(a == b)
        #expect(a != c)
    }
}
```

`Tests/EspalierKitTests/Keybinds/GhosttyActionTests.swift`:

```swift
import Testing
@testable import EspalierKit

@Suite("GhosttyAction — action-name contract")
struct GhosttyActionTests {
    @Test func rawValuesMatchGhosttyConfigSyntax() {
        // These strings are the exact names Ghostty's config parser
        // recognizes. Changing them orphans the bridge.
        #expect(GhosttyAction.newSplitRight.rawValue == "new_split:right")
        #expect(GhosttyAction.newSplitLeft.rawValue  == "new_split:left")
        #expect(GhosttyAction.newSplitUp.rawValue    == "new_split:up")
        #expect(GhosttyAction.newSplitDown.rawValue  == "new_split:down")
        #expect(GhosttyAction.closeSurface.rawValue  == "close_surface")
        #expect(GhosttyAction.gotoSplitLeft.rawValue   == "goto_split:left")
        #expect(GhosttyAction.gotoSplitRight.rawValue  == "goto_split:right")
        #expect(GhosttyAction.gotoSplitTop.rawValue    == "goto_split:top")
        #expect(GhosttyAction.gotoSplitBottom.rawValue == "goto_split:bottom")
        #expect(GhosttyAction.gotoSplitPrevious.rawValue == "goto_split:previous")
        #expect(GhosttyAction.gotoSplitNext.rawValue     == "goto_split:next")
        #expect(GhosttyAction.toggleSplitZoom.rawValue == "toggle_split_zoom")
        #expect(GhosttyAction.equalizeSplits.rawValue  == "equalize_splits")
        #expect(GhosttyAction.reloadConfig.rawValue    == "reload_config")
    }

    @Test func allCasesCountMatchesEnumSize() {
        #expect(GhosttyAction.allCases.count == 14)
    }
}
```

- [ ] **Step 2: Run, verify fail**

```bash
swift test --filter ShortcutChordTests --filter GhosttyActionTests
```

Expected: FAIL — types not defined.

- [ ] **Step 3: Create files**

`Sources/EspalierKit/Keybinds/ShortcutChord.swift`:

```swift
import Foundation

/// Keyboard modifiers carried by a `ShortcutChord`. Pure value type — no
/// SwiftUI or libghostty dependency, so the bridge can be tested in
/// isolation.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift   = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option  = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)
}

/// A keyboard chord: the key plus the modifier set.
///
/// `key` is a short, printable token identifying the physical key:
/// lowercase letters `"a"`..`"z"`; digits `"0"`..`"9"`; `"arrowleft"`,
/// `"arrowright"`, `"arrowup"`, `"arrowdown"`; `"return"`, `"tab"`,
/// `"space"`, `"escape"`, `"backspace"`, `"delete"`; `"f1"`..`"f24"`;
/// plus punctuation tokens (`"comma"`, `"period"`, etc.).
///
/// The app-target adapter produces these from `ghostty_input_trigger_s`
/// and the SwiftUI layer consumes them via `KeyboardShortcutFromChord`.
public struct ShortcutChord: Hashable, Sendable, Codable {
    public let key: String
    public let modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}
```

`Sources/EspalierKit/Keybinds/GhosttyAction.swift`:

```swift
import Foundation

/// Subset of Ghostty apprt actions Espalier exposes as menu items and
/// queries in `GhosttyKeybindBridge`. `rawValue` is the exact string
/// Ghostty's config parser accepts on the RHS of a `keybind = chord=...`.
///
/// Changing a raw value here orphans the bridge — menu shortcut hints
/// will silently stop resolving. Tests pin every string.
public enum GhosttyAction: String, CaseIterable, Sendable {
    case newSplitRight = "new_split:right"
    case newSplitLeft  = "new_split:left"
    case newSplitUp    = "new_split:up"
    case newSplitDown  = "new_split:down"
    case closeSurface  = "close_surface"
    case gotoSplitLeft   = "goto_split:left"
    case gotoSplitRight  = "goto_split:right"
    case gotoSplitTop    = "goto_split:top"
    case gotoSplitBottom = "goto_split:bottom"
    case gotoSplitPrevious = "goto_split:previous"
    case gotoSplitNext     = "goto_split:next"
    case toggleSplitZoom = "toggle_split_zoom"
    case equalizeSplits  = "equalize_splits"
    case reloadConfig    = "reload_config"
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter ShortcutChordTests --filter GhosttyActionTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Keybinds Tests/EspalierKitTests/Keybinds/ShortcutChordTests.swift Tests/EspalierKitTests/Keybinds/GhosttyActionTests.swift
git commit -m "feat(kit): ShortcutChord + GhosttyAction pure-Swift types"
```

---

## Task 7: `GhosttyKeybindBridge` with resolver closure

**Files:**
- Create: `Sources/EspalierKit/Keybinds/GhosttyKeybindBridge.swift`
- Create: `Tests/EspalierKitTests/Keybinds/GhosttyKeybindBridgeTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import EspalierKit

@Suite("GhosttyKeybindBridge")
struct GhosttyKeybindBridgeTests {
    @Test func subscriptReturnsResolvedChord() {
        let bridge = GhosttyKeybindBridge { name in
            name == "new_split:right"
                ? ShortcutChord(key: "d", modifiers: [.command])
                : nil
        }
        #expect(bridge[.newSplitRight] == ShortcutChord(key: "d", modifiers: [.command]))
        #expect(bridge[.closeSurface] == nil)
    }

    @Test func bridgeQueriesEveryActionOnce() {
        var queried: [String] = []
        _ = GhosttyKeybindBridge { name in
            queried.append(name)
            return nil
        }
        #expect(Set(queried) == Set(GhosttyAction.allCases.map(\.rawValue)))
        #expect(queried.count == GhosttyAction.allCases.count,
                "no duplicate queries")
    }

    @Test func unresolvedActionReturnsNil() {
        let bridge = GhosttyKeybindBridge { _ in nil }
        for action in GhosttyAction.allCases {
            #expect(bridge[action] == nil, "\(action) should be unresolved")
        }
    }
}
```

- [ ] **Step 2: Run, verify fail**

```bash
swift test --filter GhosttyKeybindBridgeTests
```

Expected: FAIL — bridge not defined.

- [ ] **Step 3: Implement**

`Sources/EspalierKit/Keybinds/GhosttyKeybindBridge.swift`:

```swift
import Foundation

/// Resolves Ghostty apprt action names to chords. Built once at app
/// launch from `ghostty_config_trigger` via the resolver closure the
/// app target provides.
///
/// Pure value type — no GhosttyKit, no SwiftUI. The app target wraps
/// the raw libghostty call in a closure of shape
/// `(actionName) -> ShortcutChord?` and hands it to the init.
public struct GhosttyKeybindBridge: Sendable {
    public typealias Resolver = @Sendable (String) -> ShortcutChord?

    private let chords: [GhosttyAction: ShortcutChord]

    public init(resolver: Resolver) {
        var map: [GhosttyAction: ShortcutChord] = [:]
        for action in GhosttyAction.allCases {
            map[action] = resolver(action.rawValue)
        }
        self.chords = map
    }

    public subscript(action: GhosttyAction) -> ShortcutChord? {
        chords[action]
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter GhosttyKeybindBridgeTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Keybinds/GhosttyKeybindBridge.swift Tests/EspalierKitTests/Keybinds/GhosttyKeybindBridgeTests.swift
git commit -m "feat(kit): GhosttyKeybindBridge with resolver closure"
```

---

## Task 8: `GhosttyTriggerAdapter` (app-target GhosttyKit → `ShortcutChord`)

**Files:**
- Create: `Sources/Espalier/Terminal/GhosttyTriggerAdapter.swift`

No test target available for the app module; this adapter is intentionally trivial (two switches + a bitfield map). Smoke test via the end-to-end build.

- [ ] **Step 1: Write the adapter**

`Sources/Espalier/Terminal/GhosttyTriggerAdapter.swift`:

```swift
import Foundation
import GhosttyKit
import EspalierKit

/// Translates libghostty's `ghostty_input_trigger_s` into Espalier's
/// pure-Swift `ShortcutChord`. Lives in the app target because it's
/// the only module that imports GhosttyKit.
enum GhosttyTriggerAdapter {
    /// Returns nil when the trigger is unbound (key enum is
    /// `GHOSTTY_KEY_UNIDENTIFIED`) or maps to an enum value we don't
    /// yet have a string token for (logged at debug for visibility).
    static func chord(from trigger: ghostty_input_trigger_s) -> ShortcutChord? {
        guard let key = keyString(trigger.key) else { return nil }
        return ShortcutChord(key: key, modifiers: modifiers(trigger.mods))
    }

    /// Factory for the closure `GhosttyKeybindBridge.init(resolver:)`
    /// expects. Captures the `ghostty_config_t` and calls
    /// `ghostty_config_trigger` on each lookup.
    static func resolver(config: ghostty_config_t) -> GhosttyKeybindBridge.Resolver {
        { actionName in
            let trigger = actionName.withCString { cstr in
                ghostty_config_trigger(config, cstr, actionName.utf8.count)
            }
            return chord(from: trigger)
        }
    }

    // MARK: - Private

    private static func modifiers(_ raw: ghostty_input_mods_e) -> ShortcutModifiers {
        var out: ShortcutModifiers = []
        if (raw.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0 { out.insert(.shift) }
        if (raw.rawValue & GHOSTTY_MODS_CTRL.rawValue)  != 0 { out.insert(.control) }
        if (raw.rawValue & GHOSTTY_MODS_ALT.rawValue)   != 0 { out.insert(.option) }
        if (raw.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0 { out.insert(.command) }
        return out
    }

    private static func keyString(_ key: ghostty_input_key_e) -> String? {
        // Exhaustive mapping for the key enum values libghostty can
        // realistically bind. Returns nil for GHOSTTY_KEY_UNIDENTIFIED
        // and anything we haven't mapped yet.
        switch key {
        case GHOSTTY_KEY_A: return "a"
        case GHOSTTY_KEY_B: return "b"
        case GHOSTTY_KEY_C: return "c"
        case GHOSTTY_KEY_D: return "d"
        case GHOSTTY_KEY_E: return "e"
        case GHOSTTY_KEY_F: return "f"
        case GHOSTTY_KEY_G: return "g"
        case GHOSTTY_KEY_H: return "h"
        case GHOSTTY_KEY_I: return "i"
        case GHOSTTY_KEY_J: return "j"
        case GHOSTTY_KEY_K: return "k"
        case GHOSTTY_KEY_L: return "l"
        case GHOSTTY_KEY_M: return "m"
        case GHOSTTY_KEY_N: return "n"
        case GHOSTTY_KEY_O: return "o"
        case GHOSTTY_KEY_P: return "p"
        case GHOSTTY_KEY_Q: return "q"
        case GHOSTTY_KEY_R: return "r"
        case GHOSTTY_KEY_S: return "s"
        case GHOSTTY_KEY_T: return "t"
        case GHOSTTY_KEY_U: return "u"
        case GHOSTTY_KEY_V: return "v"
        case GHOSTTY_KEY_W: return "w"
        case GHOSTTY_KEY_X: return "x"
        case GHOSTTY_KEY_Y: return "y"
        case GHOSTTY_KEY_Z: return "z"
        case GHOSTTY_KEY_DIGIT_0: return "0"
        case GHOSTTY_KEY_DIGIT_1: return "1"
        case GHOSTTY_KEY_DIGIT_2: return "2"
        case GHOSTTY_KEY_DIGIT_3: return "3"
        case GHOSTTY_KEY_DIGIT_4: return "4"
        case GHOSTTY_KEY_DIGIT_5: return "5"
        case GHOSTTY_KEY_DIGIT_6: return "6"
        case GHOSTTY_KEY_DIGIT_7: return "7"
        case GHOSTTY_KEY_DIGIT_8: return "8"
        case GHOSTTY_KEY_DIGIT_9: return "9"
        case GHOSTTY_KEY_ARROW_LEFT:  return "arrowleft"
        case GHOSTTY_KEY_ARROW_RIGHT: return "arrowright"
        case GHOSTTY_KEY_ARROW_UP:    return "arrowup"
        case GHOSTTY_KEY_ARROW_DOWN:  return "arrowdown"
        case GHOSTTY_KEY_ENTER:       return "return"
        case GHOSTTY_KEY_TAB:         return "tab"
        case GHOSTTY_KEY_SPACE:       return "space"
        case GHOSTTY_KEY_ESCAPE:      return "escape"
        case GHOSTTY_KEY_BACKSPACE:   return "backspace"
        case GHOSTTY_KEY_DELETE:      return "delete"
        case GHOSTTY_KEY_HOME:        return "home"
        case GHOSTTY_KEY_END:         return "end"
        case GHOSTTY_KEY_PAGE_UP:     return "pageup"
        case GHOSTTY_KEY_PAGE_DOWN:   return "pagedown"
        case GHOSTTY_KEY_COMMA:       return "comma"
        case GHOSTTY_KEY_PERIOD:      return "period"
        case GHOSTTY_KEY_SEMICOLON:   return "semicolon"
        case GHOSTTY_KEY_QUOTE:       return "quote"
        case GHOSTTY_KEY_BRACKET_LEFT:  return "bracketleft"
        case GHOSTTY_KEY_BRACKET_RIGHT: return "bracketright"
        case GHOSTTY_KEY_SLASH:       return "slash"
        case GHOSTTY_KEY_BACKSLASH:   return "backslash"
        case GHOSTTY_KEY_BACKQUOTE:   return "backquote"
        case GHOSTTY_KEY_MINUS:       return "minus"
        case GHOSTTY_KEY_EQUAL:       return "equal"
        case GHOSTTY_KEY_F1:  return "f1"
        case GHOSTTY_KEY_F2:  return "f2"
        case GHOSTTY_KEY_F3:  return "f3"
        case GHOSTTY_KEY_F4:  return "f4"
        case GHOSTTY_KEY_F5:  return "f5"
        case GHOSTTY_KEY_F6:  return "f6"
        case GHOSTTY_KEY_F7:  return "f7"
        case GHOSTTY_KEY_F8:  return "f8"
        case GHOSTTY_KEY_F9:  return "f9"
        case GHOSTTY_KEY_F10: return "f10"
        case GHOSTTY_KEY_F11: return "f11"
        case GHOSTTY_KEY_F12: return "f12"
        default:
            // GHOSTTY_KEY_UNIDENTIFIED or an enum we haven't translated.
            // Menu item will render without a shortcut hint.
            return nil
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build --configuration debug
```

Expected: success. (If specific `GHOSTTY_KEY_*` names don't exist in the vendored libghostty-spm header, strip the missing cases — check `/Users/btucker/projects/espalier/.worktrees/ghostty-keybinds/.build/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h` line ~128 onward for the exact enum values. At minimum keep letters, digits, arrows, common punctuation, F-keys.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Espalier/Terminal/GhosttyTriggerAdapter.swift
git commit -m "feat(app): GhosttyTriggerAdapter — libghostty trigger → ShortcutChord"
```

---

## Task 9: `KeyboardShortcutFromChord` (SwiftUI translator)

**Files:**
- Create: `Sources/Espalier/Terminal/KeyboardShortcutFromChord.swift`

- [ ] **Step 1: Write**

```swift
import SwiftUI
import EspalierKit

/// Translates Espalier's pure `ShortcutChord` into SwiftUI's
/// `KeyboardShortcut`. Unmapped keys return `nil` — the caller must
/// gracefully skip the `.keyboardShortcut(...)` modifier.
enum KeyboardShortcutFromChord {
    static func shortcut(from chord: ShortcutChord) -> KeyboardShortcut? {
        guard let equivalent = keyEquivalent(from: chord.key) else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers(from: chord.modifiers))
    }

    private static func eventModifiers(from m: ShortcutModifiers) -> EventModifiers {
        var out: EventModifiers = []
        if m.contains(.shift)   { out.insert(.shift) }
        if m.contains(.control) { out.insert(.control) }
        if m.contains(.option)  { out.insert(.option) }
        if m.contains(.command) { out.insert(.command) }
        return out
    }

    private static func keyEquivalent(from token: String) -> KeyEquivalent? {
        if token.count == 1, let scalar = token.unicodeScalars.first {
            return KeyEquivalent(Character(scalar))
        }
        switch token {
        case "arrowleft":  return .leftArrow
        case "arrowright": return .rightArrow
        case "arrowup":    return .upArrow
        case "arrowdown":  return .downArrow
        case "return":     return .return
        case "tab":        return .tab
        case "space":      return .space
        case "escape":     return .escape
        case "delete":     return .delete
        case "backspace":  return .deleteForward   // SwiftUI naming; `.delete` is forward-delete
        case "home":       return .home
        case "end":        return .end
        case "pageup":     return .pageUp
        case "pagedown":   return .pageDown
        // Punctuation / f-keys fall through to nil; SwiftUI
        // KeyEquivalent only has named constants for a few.
        default:
            return nil
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build --configuration debug
```

Expected: success. If a SwiftUI `KeyEquivalent` constant is misnamed for your SDK version, consult the SwiftUI docs and adjust (e.g. `.home` is macOS 13+; fallback to `nil` for unavailable ones).

- [ ] **Step 3: Commit**

```bash
git add Sources/Espalier/Terminal/KeyboardShortcutFromChord.swift
git commit -m "feat(app): ShortcutChord → SwiftUI KeyboardShortcut translator"
```

---

## Task 10: Expose `keybindBridge` on `TerminalManager` + plumb callbacks

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift`

- [ ] **Step 1: Add bridge + callback fields**

In `TerminalManager.swift`, just after the existing `@Published var titles`:

```swift
/// Ghostty-config-derived keybind map, built in `initialize()` from the
/// live `ghostty_config_t` via `GhosttyTriggerAdapter.resolver`.
/// `EspalierApp.commands` reads this to set menu `.keyboardShortcut(...)`
/// modifiers dynamically.
@Published private(set) var keybindBridge: GhosttyKeybindBridge =
    GhosttyKeybindBridge(resolver: { _ in nil })
```

Add these closure fields alongside the existing `onSplitRequest` etc.:

```swift
/// Called when libghostty dispatches `toggle_split_zoom`. Host flips the
/// `zoomed` state on the worktree containing `terminalID`.
var onToggleZoom: ((TerminalID) -> Void)?

/// Called on `resize_split`. Host walks up the split tree for the focused
/// worktree, finds the matching-orientation ancestor's bounds from the
/// current SwiftUI layout, and applies `SplitTree.resizing(...)`.
var onResizeSplit: ((TerminalID, ResizeDirection, UInt16) -> Void)?

/// Called on `equalize_splits`. Host runs `SplitTree.equalizing()` on the
/// worktree containing `terminalID`.
var onEqualizeSplits: ((TerminalID) -> Void)?

/// Called on `reload_config`. Host asks libghostty to reload and then
/// calls `TerminalManager.rebuildKeybindBridge()` so menu shortcuts
/// update to match the new config.
var onReloadConfig: (() -> Void)?
```

- [ ] **Step 2: Build bridge in `initialize()`**

At the end of `initialize()` (after `wakeupObserver = …`), add:

```swift
if let config = ghosttyConfig?.config {
    self.keybindBridge = GhosttyKeybindBridge(
        resolver: GhosttyTriggerAdapter.resolver(config: config)
    )
}
```

Also add a public helper so `onReloadConfig` can rebuild:

```swift
/// Rebuild the keybind bridge from the current config. Call after
/// `ghostty_config_*` reload operations.
func rebuildKeybindBridge() {
    guard let config = ghosttyConfig?.config else { return }
    self.keybindBridge = GhosttyKeybindBridge(
        resolver: GhosttyTriggerAdapter.resolver(config: config)
    )
}
```

- [ ] **Step 3: Build**

```bash
swift build --configuration debug
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift
git commit -m "feat(app): TerminalManager exposes keybindBridge + zoom/resize/reload callbacks"
```

---

## Task 11: Add `handleAction` cases for Espalier-modelable actions

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift`

- [ ] **Step 1: Locate `handleAction`**

Find the switch in `handleAction(target:action:)`. Add new cases alongside `GHOSTTY_ACTION_COMMAND_FINISHED` / `GHOSTTY_ACTION_SHOW_CHILD_EXITED` (latter already exists from the exit-bug fix).

- [ ] **Step 2: Add cases**

```swift
case GHOSTTY_ACTION_NEW_SPLIT:
    guard let id = terminalID(from: target) else { return }
    let split: PaneSplit
    switch action.action.new_split {
    case GHOSTTY_SPLIT_DIRECTION_RIGHT: split = .right
    case GHOSTTY_SPLIT_DIRECTION_LEFT:  split = .left
    case GHOSTTY_SPLIT_DIRECTION_UP:    split = .up
    case GHOSTTY_SPLIT_DIRECTION_DOWN:  split = .down
    default: return
    }
    onSplitRequest?(id, split)

case GHOSTTY_ACTION_CLOSE_TAB:
    // Ghostty reuses close_tab for close_surface in single-pane
    // contexts; Espalier treats pane close the same way.
    guard let id = terminalID(from: target) else { return }
    onCloseRequest?(id)

case GHOSTTY_ACTION_GOTO_SPLIT:
    guard let id = terminalID(from: target) else { return }
    let gotoDir = action.action.goto_split
    let direction: NavigationDirection?
    switch gotoDir {
    case GHOSTTY_GOTO_SPLIT_LEFT:   direction = .left
    case GHOSTTY_GOTO_SPLIT_RIGHT:  direction = .right
    case GHOSTTY_GOTO_SPLIT_TOP:    direction = .up
    case GHOSTTY_GOTO_SPLIT_BOTTOM: direction = .down
    case GHOSTTY_GOTO_SPLIT_PREVIOUS, GHOSTTY_GOTO_SPLIT_NEXT:
        // Handled separately below — traversal, not spatial nav.
        direction = nil
    default: return
    }
    if let direction {
        onGotoSplit?(id, direction)
    } else {
        let forward = (gotoDir == GHOSTTY_GOTO_SPLIT_NEXT)
        onGotoSplitOrder?(id, forward)
    }

case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
    guard let id = terminalID(from: target) else { return }
    onToggleZoom?(id)

case GHOSTTY_ACTION_RESIZE_SPLIT:
    guard let id = terminalID(from: target) else { return }
    let r = action.action.resize_split
    let direction: ResizeDirection
    switch r.direction {
    case GHOSTTY_RESIZE_SPLIT_UP:    direction = .up
    case GHOSTTY_RESIZE_SPLIT_DOWN:  direction = .down
    case GHOSTTY_RESIZE_SPLIT_LEFT:  direction = .left
    case GHOSTTY_RESIZE_SPLIT_RIGHT: direction = .right
    default: return
    }
    onResizeSplit?(id, direction, r.amount)

case GHOSTTY_ACTION_EQUALIZE_SPLITS:
    guard let id = terminalID(from: target) else { return }
    onEqualizeSplits?(id)

case GHOSTTY_ACTION_RELOAD_CONFIG:
    onReloadConfig?()

// Silent no-ops for Ghostty concepts Espalier doesn't model. Listed
// explicitly (rather than falling into default) so future maintainers
// know we looked at them.
case GHOSTTY_ACTION_NEW_TAB,
     GHOSTTY_ACTION_MOVE_TAB,
     GHOSTTY_ACTION_GOTO_TAB,
     GHOSTTY_ACTION_NEW_WINDOW,
     GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
     GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
     GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
     GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
     GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
     GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
     GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
     GHOSTTY_ACTION_CHECK_FOR_UPDATES,
     GHOSTTY_ACTION_OPEN_CONFIG:
    break
```

Add the missing callback fields at the top of the class where the other `on*` are declared:

```swift
var onGotoSplit: ((TerminalID, NavigationDirection) -> Void)?
var onGotoSplitOrder: ((TerminalID, _ forward: Bool) -> Void)?
```

And move the `NavigationDirection` enum from `EspalierApp.swift` to `TerminalManager.swift` (or keep it where it is and import it — plan keeps it in `EspalierApp` and uses the fully-qualified name `EspalierApp.NavigationDirection` or promotes to a top-level type; simplest is promote):

```swift
enum NavigationDirection {
    case left, right, up, down
}
```

Replace `EspalierApp.NavigationDirection` references to use the top-level type.

- [ ] **Step 3: Build**

```bash
swift build --configuration debug
```

Expected: success. (If any `GHOSTTY_ACTION_*` or `GHOSTTY_SPLIT_DIRECTION_*` enum case name is different in the vendored header, check ghostty.h and adjust — the header will have the exact values. At the file `/Users/btucker/projects/espalier/.worktrees/ghostty-keybinds/.build/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h`.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift
git commit -m "feat(app): handleAction cases for new_split/goto_split/zoom/resize/equalize/reload_config"
```

---

## Task 12: Wire callbacks in `EspalierApp`, add new menu items, bridge shortcuts

**Files:**
- Modify: `Sources/Espalier/EspalierApp.swift`

- [ ] **Step 1: Wire callbacks**

In `startup()`, after the existing `terminalManager.onCloseRequest = …`:

```swift
terminalManager.onGotoSplit = { [appState = $appState, tm = terminalManager] terminalID, direction in
    MainActor.assumeIsolated {
        Self.navigatePane(appState: appState, terminalManager: tm, from: terminalID, direction: direction)
    }
}

terminalManager.onGotoSplitOrder = { [appState = $appState, tm = terminalManager] terminalID, forward in
    MainActor.assumeIsolated {
        Self.navigatePaneInTreeOrder(appState: appState, terminalManager: tm, from: terminalID, forward: forward)
    }
}

terminalManager.onToggleZoom = { [appState = $appState] terminalID in
    MainActor.assumeIsolated {
        Self.toggleZoom(appState: appState, on: terminalID)
    }
}

terminalManager.onResizeSplit = { [appState = $appState] terminalID, direction, amount in
    MainActor.assumeIsolated {
        Self.resizeSplit(appState: appState, target: terminalID, direction: direction, pixels: amount)
    }
}

terminalManager.onEqualizeSplits = { [appState = $appState] terminalID in
    MainActor.assumeIsolated {
        Self.equalizeSplits(appState: appState, around: terminalID)
    }
}

terminalManager.onReloadConfig = { [tm = terminalManager] in
    MainActor.assumeIsolated {
        // Ghostty doesn't expose a C reload entry today; best-effort:
        // rebuild the bridge from the still-live config object. Future:
        // ghostty_config_reload if libghostty-spm surfaces one.
        tm.rebuildKeybindBridge()
    }
}
```

- [ ] **Step 2: Implement helpers**

Alongside the existing `fileprivate static func closePane` / `splitPane`:

```swift
@MainActor
fileprivate static func toggleZoom(appState: Binding<AppState>, on terminalID: TerminalID) {
    mutateWorktreeContaining(appState: appState, leaf: terminalID) { wt in
        var copy = wt
        copy.splitTree = wt.splitTree.togglingZoom(at: terminalID)
        return copy
    }
}

@MainActor
fileprivate static func equalizeSplits(appState: Binding<AppState>, around terminalID: TerminalID) {
    mutateWorktreeContaining(appState: appState, leaf: terminalID) { wt in
        var copy = wt
        copy.splitTree = wt.splitTree.equalizing()
        return copy
    }
}

@MainActor
fileprivate static func resizeSplit(
    appState: Binding<AppState>,
    target: TerminalID,
    direction: ResizeDirection,
    pixels: UInt16
) {
    // Bounds: we don't have live per-split GeometryReader plumbing yet,
    // so as an MVP, pass the window's content-area bounds for the
    // focused worktree's split root. This approximates the ancestor
    // bounds for the common case (one split layer). A follow-up can
    // capture per-split bounds via preference keys for multi-level
    // accuracy.
    let bounds = NSApp.keyWindow?.contentView?.bounds ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
    mutateWorktreeContaining(appState: appState, leaf: target) { wt in
        var copy = wt
        do {
            copy.splitTree = try wt.splitTree.resizing(
                target: target,
                direction: direction,
                pixels: pixels,
                ancestorBounds: bounds
            )
        } catch {
            // No matching ancestor — silent no-op, matches Ghostty.
        }
        return copy
    }
}

@MainActor
fileprivate static func navigatePaneInTreeOrder(
    appState: Binding<AppState>,
    terminalManager: TerminalManager,
    from terminalID: TerminalID,
    forward: Bool
) {
    for repoIdx in appState.wrappedValue.repos.indices {
        for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
            let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
            let leaves = wt.splitTree.allLeaves
            guard let currentIdx = leaves.firstIndex(of: terminalID) else { continue }
            let nextIdx = forward
                ? (currentIdx + 1) % leaves.count
                : (currentIdx - 1 + leaves.count) % leaves.count
            let nextID = leaves[nextIdx]
            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = nextID
            terminalManager.setFocus(nextID)
            return
        }
    }
}

@MainActor
private static func mutateWorktreeContaining(
    appState: Binding<AppState>,
    leaf: TerminalID,
    transform: (Worktree) -> Worktree
) {
    for repoIdx in appState.wrappedValue.repos.indices {
        for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
            if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree.allLeaves.contains(leaf) {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx] = transform(wt)
                return
            }
        }
    }
}
```

- [ ] **Step 3: Update `.commands` block to use bridge**

Add a SwiftUI view-builder helper near the top of `EspalierApp.swift`:

```swift
/// Wraps a menu button so its keyboard shortcut is derived from the
/// keybind bridge, not hardcoded. If the action isn't bound (e.g., user
/// removed the keybind from their Ghostty config), the button renders
/// without a shortcut hint.
@MainActor
@ViewBuilder
private func bridgedButton(
    _ label: LocalizedStringKey,
    action: GhosttyAction,
    onTap: @escaping () -> Void
) -> some View {
    if let chord = terminalManager.keybindBridge[action],
       let shortcut = KeyboardShortcutFromChord.shortcut(from: chord)
    {
        Button(label, action: onTap).keyboardShortcut(shortcut)
    } else {
        Button(label, action: onTap)
    }
}
```

Rewrite the `.commands` block:

```swift
.commands {
    CommandGroup(after: .newItem) {
        Button("Add Repository...") { ... }  // keep Cmd+Shift+O hardcoded — Espalier-specific
            .keyboardShortcut("o", modifiers: [.command, .shift])

        bridgedButton("Split Right",  action: .newSplitRight)  { self.handleSplit(.right) }
        bridgedButton("Split Left",   action: .newSplitLeft)   { self.handleSplit(.left) }
        bridgedButton("Split Down",   action: .newSplitDown)   { self.handleSplit(.down) }
        bridgedButton("Split Up",     action: .newSplitUp)     { self.handleSplit(.up) }

        bridgedButton("Navigate Left",  action: .gotoSplitLeft)   { self.handleNavigate(.left) }
        bridgedButton("Navigate Right", action: .gotoSplitRight)  { self.handleNavigate(.right) }
        bridgedButton("Navigate Up",    action: .gotoSplitTop)    { self.handleNavigate(.up) }
        bridgedButton("Navigate Down",  action: .gotoSplitBottom) { self.handleNavigate(.down) }

        bridgedButton("Previous Pane", action: .gotoSplitPrevious) { self.handleNavigateTreeOrder(forward: false) }
        bridgedButton("Next Pane",     action: .gotoSplitNext)     { self.handleNavigateTreeOrder(forward: true) }

        bridgedButton("Zoom Split",      action: .toggleSplitZoom)  { self.handleToggleZoom() }
        bridgedButton("Equalize Splits", action: .equalizeSplits)   { self.handleEqualizeSplits() }

        bridgedButton("Close Pane", action: .closeSurface) { self.handleClosePane() }
    }

    CommandGroup(after: .appInfo) {
        Button("Install CLI Tool...") { installCLI() }
        bridgedButton("Reload Ghostty Config", action: .reloadConfig) { self.handleReloadConfig() }
    }
}
```

And add the tiny dispatch methods that pull from the currently-focused pane:

```swift
private func handleSplit(_ split: PaneSplit) {
    guard let id = focusedTerminalID else { return }
    _ = Self.splitPane(appState: $appState, terminalManager: terminalManager, targetID: id, split: split)
}

private func handleNavigate(_ dir: NavigationDirection) {
    guard let id = focusedTerminalID else { return }
    Self.navigatePane(appState: $appState, terminalManager: terminalManager, from: id, direction: dir)
}

private func handleNavigateTreeOrder(forward: Bool) {
    guard let id = focusedTerminalID else { return }
    Self.navigatePaneInTreeOrder(appState: $appState, terminalManager: terminalManager, from: id, forward: forward)
}

private func handleToggleZoom() {
    guard let id = focusedTerminalID else { return }
    Self.toggleZoom(appState: $appState, on: id)
}

private func handleEqualizeSplits() {
    guard let id = focusedTerminalID else { return }
    Self.equalizeSplits(appState: $appState, around: id)
}

private func handleClosePane() {
    guard let id = focusedTerminalID else { return }
    Self.closePane(appState: $appState, terminalManager: terminalManager, targetID: id)
}

private func handleReloadConfig() {
    terminalManager.rebuildKeybindBridge()
}
```

(`focusedTerminalID` is a computed property reading from `appState`; already exists in some form — reuse.)

- [ ] **Step 4: Build**

```bash
swift build --configuration debug
```

Expected: success. Fix up any `NavigationDirection` import / naming mismatches the earlier task surfaced.

- [ ] **Step 5: Commit**

```bash
git add Sources/Espalier/EspalierApp.swift
git commit -m "feat(app): bridged menu shortcuts + zoom/resize/equalize/reload handlers"
```

---

## Task 13: Render zoomed pane in `SplitContainerView`

**Files:**
- Modify: `Sources/Espalier/Views/SplitContainerView.swift`

- [ ] **Step 1: Inspect current structure**

```bash
cat Sources/Espalier/Views/SplitContainerView.swift
```

Find the top-level body that builds the split tree view hierarchy.

- [ ] **Step 2: Branch on zoom state at the root**

Add at the top of the body (before dispatching into the split-tree renderer):

```swift
var body: some View {
    if let zoomedID = worktree.splitTree.zoomed {
        // Zoom path: render only the zoomed leaf full-bleed.
        // SurfaceViewWrapper is already stable by ID, so this is a
        // SwiftUI view-switch rather than a surface lifecycle event.
        SurfaceViewWrapper(terminalID: zoomedID)
            .focusable()
    } else {
        // Normal split-tree rendering (existing body moves here).
        existingSplitTreeView(for: worktree.splitTree.root)
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build --configuration debug
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/Views/SplitContainerView.swift
git commit -m "feat(app): SplitContainerView renders only the zoomed leaf when set"
```

---

## Task 14: Honor `split-preserve-zoom = navigation` config flag

**Files:**
- Modify: `Sources/Espalier/Terminal/TerminalManager.swift`
- Modify: `Sources/Espalier/EspalierApp.swift`

- [ ] **Step 1: Expose the flag on `TerminalManager`**

```swift
/// True when the user's Ghostty config has `split-preserve-zoom =
/// navigation` (explicit opt-in introduced in Ghostty 1.3). When true,
/// a goto_split from a zoomed pane transfers zoom to the newly focused
/// leaf instead of unzooming.
@Published private(set) var splitPreserveZoomOnNavigation: Bool = false
```

Populate it in `initialize()` and in `rebuildKeybindBridge()`:

```swift
private func readSplitPreserveZoomConfig() {
    guard let config = ghosttyConfig?.config else { return }
    var present: Bool = false
    "split-preserve-zoom".withCString { cstr in
        var raw: UnsafePointer<CChar>? = nil
        // `ghostty_config_get` writes into `raw` for string configs.
        // If the config's value contains the substring "navigation",
        // the flag is on. Ghostty serializes multi-value configs as
        // comma-separated strings.
        _ = ghostty_config_get(config, &raw, cstr, UInt(strlen(cstr)))
        if let raw, strstr(raw, "navigation") != nil { present = true }
    }
    self.splitPreserveZoomOnNavigation = present
}
```

Call `readSplitPreserveZoomConfig()` at the end of `initialize()` and `rebuildKeybindBridge()`.

- [ ] **Step 2: Update `navigatePane` to check the flag**

In `EspalierApp.navigatePane` (and its `navigatePaneInTreeOrder` sibling), after computing the next leaf, before setting focus:

```swift
// Zoom preservation: Ghostty 1.3 split-preserve-zoom=navigation.
var tree = wt.splitTree
if tree.zoomed != nil {
    if terminalManager.splitPreserveZoomOnNavigation {
        tree = tree.withZoom(nextID)
    } else {
        tree = tree.withZoom(nil)
    }
    appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = tree
}
```

- [ ] **Step 3: Build**

```bash
swift build --configuration debug
```

Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/Terminal/TerminalManager.swift Sources/Espalier/EspalierApp.swift
git commit -m "feat(app): honor split-preserve-zoom=navigation for zoom-during-nav"
```

---

## Task 15: Add SPECS §14

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Append §14**

Append to the bottom of `SPECS.md`:

```markdown
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

- [ ] **Step 2: Commit**

```bash
git add SPECS.md
git commit -m "docs(specs): §14 keyboard shortcuts — config-driven keybind parity"
```

---

## Task 16: Full build + test sweep

**Files:** none

- [ ] **Step 1: Run everything**

```bash
cd /Users/btucker/projects/espalier/.worktrees/ghostty-keybinds
swift build --configuration debug 2>&1 | tail
swift test --filter EspalierKitTests 2>&1 | tail -30
scripts/bundle.sh 2>&1 | tail -10
```

Expected: build succeeds, every test passes, bundle produced.

- [ ] **Step 2: Smoke-test the bundled app**

Manual checklist (from the spec):

1. Open `.build/Espalier.app`. Open a pane. Press `Cmd+D` → split right.
2. Verify menu bar shows "Split Right" with `⌘D` hint.
3. Press `Cmd+Shift+Return` → pane zooms. Press again → unzooms.
4. With a 3-way split (split right once, then split down on the right pane), press `Cmd+Opt+Shift+Right` → verify only the inner vertical divider moves.
5. Press a `Cmd+T` (Ghostty's default tab chord) → verify no visible effect and no crash.
6. Type `exit` in the focused pane → verify the pane closes (regression check on the previous fix).

If any of the above fails, abort and fix before continuing to Task 17.

- [ ] **Step 3: Commit smoke-test notes (if applicable)**

If the smoke test revealed anything, capture as a follow-up note; otherwise nothing to commit.

---

## Task 17: Open the PR

**Files:** none

- [ ] **Step 1: Push branch**

```bash
cd /Users/btucker/projects/espalier/.worktrees/ghostty-keybinds
git push -u origin feature/ghostty-keybinds
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "feat: config-driven keybind parity with Ghostty + pane zoom + split resize" --body "$(cat <<'EOF'
## Summary
- `GhosttyKeybindBridge` resolves every in-scope Ghostty apprt action to its configured chord at app launch (and on `reload_config`).
- Menu items in `.commands` pull their `.keyboardShortcut(...)` from the bridge, so hardcoded chords are gone — user-config customizations "just work."
- `SplitTree` grows `zoomed`, `togglingZoom`, `resizing`, `equalizing`, with zoom invariants matching upstream Ghostty.
- `TerminalManager.handleAction` dispatches `NEW_SPLIT`, `GOTO_SPLIT`, `TOGGLE_SPLIT_ZOOM`, `RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `RELOAD_CONFIG`.
- Tabs / windows / quick-terminal / command-palette actions are explicit silent no-ops.

## Spec & plan
- `docs/superpowers/specs/2026-04-17-ghostty-keybinds-parity-design.md`
- `docs/superpowers/plans/2026-04-17-ghostty-keybinds-parity.md`

Covers §14 of SPECS.md. Follow-up specs (command palette, quick terminal) plug into this dispatch layer without further refactors.

## Test plan
- [x] `swift test --filter EspalierKitTests` (SplitTree zoom / resize / equalize, ShortcutChord, GhosttyAction, GhosttyKeybindBridge)
- [x] Bundle via `scripts/bundle.sh`
- [x] Smoke checklist per plan Task 16 step 2

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Print PR URL to the user.**

---

## Self-Review Notes

After writing this plan, the self-review checklist:

**Spec coverage:** Every A1-A4 action in the spec maps to either a task here (A2/A3 items) or an explicit no-op comment (A4). A1 items are noted as "already working" — no task needed.

**Placeholders:** None. Every step has exact file paths and either code blocks or shell commands. The one "MVP" shortcut — `resizeSplit` using `NSApp.keyWindow.contentView.bounds` as ancestor bounds — is explicitly called out as approximate and non-blocking, matching Ghostty's common-case behavior.

**Type consistency:** `ShortcutChord`, `ShortcutModifiers`, `GhosttyAction`, `ResizeDirection`, `SplitTreeError` — each defined once and used identically elsewhere. `NavigationDirection` is consolidated to top-level in Task 11.

**Scope:** One spec, one plan, one PR. Command palette and quick terminal remain out of scope per the spec's multi-spec header.
