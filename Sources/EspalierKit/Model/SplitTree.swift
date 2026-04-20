import Foundation
import CoreGraphics

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct SplitTree: Codable, Sendable, Equatable {
    public let root: Node?

    /// The terminal ID of the pane currently in "zoomed" state, if any.
    ///
    /// When a pane is zoomed, only it is rendered and visible; all sibling
    /// panes are hidden but remain alive in the tree. The surfaces are
    /// not torn down during zoom/unzoom — SwiftUI simply chooses which to
    /// mount.
    ///
    /// **Invariants** (ported from upstream Ghostty `SplitTree.swift:9-11`):
    /// - `inserting(newLeaf:at:direction:)` always returns with `zoomed: nil`.
    ///   Splitting from a zoomed state unzooms.
    /// - `removing(target:)` returns with `zoomed = (zoomed == target) ? nil : zoomed`.
    ///   Closing the zoomed pane auto-unzooms; closing a sibling preserves zoom.
    /// - `resizing(...)` always returns with `zoomed: nil`.
    public let zoomed: TerminalID?

    public init(root: Node?, zoomed: TerminalID? = nil) {
        self.root = root
        self.zoomed = zoomed
    }

    public indirect enum Node: Codable, Sendable, Equatable {
        case leaf(TerminalID)
        case split(Split)

        public struct Split: Codable, Sendable, Equatable {
            public let direction: SplitDirection
            public let ratio: Double
            public let left: Node
            public let right: Node

            public init(direction: SplitDirection, ratio: Double, left: Node, right: Node) {
                self.direction = direction
                self.ratio = ratio
                self.left = left
                self.right = right
            }

            public func withRatio(_ newRatio: Double) -> Split {
                Split(direction: direction, ratio: newRatio, left: left, right: right)
            }

            public func withLeft(_ newLeft: Node) -> Split {
                Split(direction: direction, ratio: ratio, left: newLeft, right: right)
            }

            public func withRight(_ newRight: Node) -> Split {
                Split(direction: direction, ratio: ratio, left: left, right: newRight)
            }
        }
    }

    // MARK: - Queries

    public var leafCount: Int {
        guard let root else { return 0 }
        return root.leafCount
    }

    public var allLeaves: [TerminalID] {
        guard let root else { return [] }
        return root.allLeaves
    }

    /// O(depth) membership check that short-circuits on the first match.
    /// Prefer over `allLeaves.contains(_:)` in hot paths — `allLeaves`
    /// allocates the full array.
    public func containsLeaf(_ id: TerminalID) -> Bool {
        root?.containsLeaf(id) ?? false
    }

    /// Resolve a user-facing 1-based pane ID (as printed by `espalier
    /// pane list`) to its underlying `TerminalID`, or nil if the ID is
    /// out of range. Uses `allLeaves` order — the same order `list`
    /// displays.
    public func leaf(atPaneID paneID: Int) -> TerminalID? {
        // Pane IDs are 1-based. Any non-positive value is out of range
        // and returns nil — matters for `paneID == Int.min`, which
        // otherwise overflows `paneID - 1` and traps the process. An
        // attacker (or a custom script with a typo) otherwise crashes
        // Espalier via `espalier pane close -- -9223372036854775808`
        // or a raw `nc -U` `.closePane` with the same index.
        guard paneID >= 1 else { return nil }
        let leaves = allLeaves
        let idx = paneID - 1
        guard leaves.indices.contains(idx) else { return nil }
        return leaves[idx]
    }

    // MARK: - Mutations (return new trees)

    public func inserting(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.inserting(newLeaf, at: target, direction: direction), zoomed: nil)
    }

    /// Like `inserting`, but the new leaf becomes the *left/top* child rather
    /// than the *right/bottom*. Used by "Split Left" / "Split Up" from the
    /// context menu — same split, opposite placement.
    public func insertingBefore(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.insertingBefore(newLeaf, at: target, direction: direction), zoomed: nil)
    }

    public func removing(_ target: TerminalID) -> SplitTree {
        guard let root else { return self }
        let newZoomed = (zoomed == target) ? nil : zoomed
        return SplitTree(root: root.removing(target), zoomed: newZoomed)
    }

    /// Compute the new `focusedTerminalID` for a worktree after a pane
    /// has been removed from its split tree (`TERM-5.6`).
    ///
    /// Contract:
    /// - Tree is now empty → nil.
    /// - `currentFocus` was the removed pane → promote to the survivor
    ///   (`remainingTree.allLeaves.first`).
    /// - `currentFocus` was some other pane → keep it. That pane is
    ///   still in `remainingTree` (removing targetID leaves others
    ///   intact), so focus stays where the user's keystrokes were going.
    ///
    /// Pre-fix, `closePane` used `remainingTree.allLeaves.first`
    /// unconditionally, so closing pane A while pane C was focused
    /// silently moved focus to pane B — a "focus jumped for no reason"
    /// UX bug. This helper is the pure policy seam callers use so the
    /// rule is testable without a live TerminalManager.
    public static func focusAfterRemoving(
        currentFocus: TerminalID?,
        removed: TerminalID,
        remainingTree: SplitTree
    ) -> TerminalID? {
        guard remainingTree.root != nil else { return nil }
        guard let currentFocus else { return nil }
        if currentFocus == removed {
            return remainingTree.allLeaves.first
        }
        return currentFocus
    }

    /// Spatial directions for `spatialNeighbor(of:direction:)`. Four cardinal
    /// directions — no diagonals.
    public enum SpatialDirection: Sendable {
        case left, right, up, down

        /// A `.left`/`.right` neighbor can only exist across a horizontal
        /// split ancestor; `.up`/`.down` only across a vertical one.
        fileprivate var requiredSplitDirection: SplitDirection {
            switch self {
            case .left, .right: return .horizontal
            case .up, .down: return .vertical
            }
        }

        /// The ancestor subtree the source must live in to HAVE a neighbor
        /// in this direction. For `.right`, the source must be on the left
        /// of a horizontal split so the right subtree is the neighbor; for
        /// `.left`, the reverse. `.down` mirrors `.right` across vertical
        /// splits (top→bottom), `.up` mirrors `.left` (bottom→top).
        fileprivate var sourceSubtreeSide: SubtreeSide {
            switch self {
            case .right, .down: return .left
            case .left, .up: return .right
            }
        }
    }

    fileprivate enum SubtreeSide { case left, right }

    /// Resolve the spatial neighbor of `terminalID` in `direction`, or nil
    /// when there is no pane adjacent in that direction (`TERM-7.3`). The
    /// algorithm walks from the leaf up to the root and, at the first
    /// ancestor whose split direction matches the requested motion AND
    /// whose source-side subtree contains us, descends the opposite
    /// subtree's "near edge" to find the landing leaf.
    ///
    /// Tree-order fallback (old behavior) is intentionally not applied
    /// here — returning nil lets the caller decide whether to ignore the
    /// keypress or loop around. Upstream Ghostty's convention is "ignore,"
    /// so the call site mirrors that.
    public func spatialNeighbor(
        of terminalID: TerminalID,
        direction: SpatialDirection
    ) -> TerminalID? {
        guard let root else { return nil }
        return root.findSpatialNeighbor(of: terminalID, direction: direction)
    }

    public func updatingRatio(for target: TerminalID, ratio: Double) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.updatingRatio(for: target, ratio: ratio), zoomed: zoomed)
    }

    /// Update the ratio of the split whose *left subtree* has `leftAnchor`
    /// as its first leaf and whose direction matches. Used to persist
    /// user-dragged divider positions — a view can identify the split it
    /// owns by `(left.allLeaves.first, direction)`, which stays stable
    /// across the brief window of a drag even for nested splits.
    public func updatingRatio(
        leftAnchor: TerminalID,
        direction: SplitDirection,
        ratio: Double
    ) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.updatingRatio(leftAnchor: leftAnchor, direction: direction, ratio: ratio), zoomed: zoomed)
    }

    /// Returns a copy with `zoomed` set to `id` (pass nil to unzoom). Leaves
    /// `root` untouched.
    public func withZoom(_ id: TerminalID?) -> SplitTree {
        SplitTree(root: root, zoomed: id)
    }

    /// Toggle the zoomed state for `leaf`:
    /// - If `leaf == zoomed`, unzooms (`zoomed: nil`).
    /// - Else if the tree has more than one leaf AND contains `leaf`, zoom that leaf.
    /// - Else (lone-leaf tree or unknown leaf), return self unchanged.
    public func togglingZoom(at leaf: TerminalID) -> SplitTree {
        guard containsLeaf(leaf), leafCount > 1 else {
            return self
        }
        return SplitTree(root: root, zoomed: (zoomed == leaf) ? nil : leaf)
    }

    /// Reset every internal split's ratio to 0.5. Clears zoom (matches
    /// upstream Ghostty: equalize implies a tree-wide rearrangement).
    public func equalizing() -> SplitTree {
        SplitTree(root: root?.equalizing(), zoomed: nil)
    }

    /// Invoke `body` for every split in the tree (depth-first). Public so
    /// tests and UI can iterate splits without re-implementing traversal.
    public func forEachSplit(_ body: (Node.Split) -> Void) {
        root?.forEachSplit(body)
    }

    /// The "breadcrumb" position of `terminalID` inside this tree — enough
    /// information to reinsert the leaf next to its former neighbor after
    /// it's been removed (e.g. when a pane moves back to a worktree it
    /// previously lived in). Nil if `terminalID` isn't in the tree or is
    /// the sole leaf (no sibling to anchor against).
    ///
    /// `anchorID` is picked as `allLeaves.first` of the original sibling
    /// subtree so it remains a useful anchor even if that subtree has
    /// itself been restructured since the leaf left.
    public func position(of terminalID: TerminalID) -> LeafPosition? {
        root?.position(of: terminalID)
    }

    public struct LeafPosition: Equatable, Sendable {
        public let anchorID: TerminalID
        public let direction: SplitDirection
        public let placement: Placement

        public enum Placement: Sendable {
            /// Target leaf was the left/top child of its enclosing split.
            case before
            /// Target leaf was the right/bottom child of its enclosing split.
            case after
        }

        public init(anchorID: TerminalID, direction: SplitDirection, placement: Placement) {
            self.anchorID = anchorID
            self.direction = direction
            self.placement = placement
        }
    }
}

extension SplitTree {
    public enum SplitTreeError: Error, Equatable {
        case noMatchingAncestor
    }

    /// Resize the nearest ancestor split of `target` whose orientation matches
    /// `direction`, by `pixels` against the given `ancestorBounds`.
    ///
    /// Ratio is clamped to [0.1, 0.9]; returned tree has `zoomed: nil`.
    /// Throws `SplitTreeError.noMatchingAncestor` when no such ancestor
    /// exists (matches upstream Ghostty's `BaseTerminalController.swift:715-717`).
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

    /// The ratio of the innermost split containing `leaf`. Used by tests
    /// and by the split-container view's resize call site.
    public func ratioOfSplit(containing leaf: TerminalID) -> Double {
        root?.ratioOfSplit(containing: leaf) ?? 0
    }

    /// The ratio of the outermost split (the root, if it's a split). Used
    /// by tests. Returns 0 if the root is a leaf or nil.
    public func ratioOfOutermostSplit() -> Double {
        guard case let .split(s) = root else { return 0 }
        return s.ratio
    }
}

extension SplitTree.Node {
    public var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(let s):
            return s.left.leafCount + s.right.leafCount
        }
    }

    public var allLeaves: [TerminalID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(let s):
            return s.left.allLeaves + s.right.allLeaves
        }
    }

    func containsLeaf(_ id: TerminalID) -> Bool {
        switch self {
        case .leaf(let leafID):
            return leafID == id
        case .split(let s):
            return s.left.containsLeaf(id) || s.right.containsLeaf(id)
        }
    }

    /// Recursive worker for `SplitTree.spatialNeighbor`. Post-order: check
    /// children first (they may answer internally), then — if the requested
    /// source subtree side matches this split and matches the required
    /// split direction — hand back the near-edge leaf of the opposite side.
    func findSpatialNeighbor(
        of terminalID: TerminalID,
        direction: SplitTree.SpatialDirection
    ) -> TerminalID? {
        guard case let .split(split) = self else { return nil }

        if split.left.containsLeaf(terminalID) {
            if let found = split.left.findSpatialNeighbor(of: terminalID, direction: direction) {
                return found
            }
            if split.direction == direction.requiredSplitDirection,
               direction.sourceSubtreeSide == .left {
                return split.right.nearEdgeLeaf(movingFrom: direction)
            }
            return nil
        }
        if split.right.containsLeaf(terminalID) {
            if let found = split.right.findSpatialNeighbor(of: terminalID, direction: direction) {
                return found
            }
            if split.direction == direction.requiredSplitDirection,
               direction.sourceSubtreeSide == .right {
                return split.left.nearEdgeLeaf(movingFrom: direction)
            }
            return nil
        }
        return nil
    }

    /// Descend into a sibling subtree to pick the leaf adjacent to the
    /// dividing boundary.
    ///
    /// When the subtree's split direction matches the motion direction —
    /// i.e., motion and split are "aligned" (`.right`/`.left` across a
    /// horizontal split, `.down`/`.up` across a vertical split) — the
    /// adjacent side is unambiguous: pick the side closest to the source.
    ///
    /// When the split direction is perpendicular to the motion, BOTH
    /// children of the split share the boundary edge equally. Convention:
    /// pick the left/top child ("reading order"), matching upstream
    /// Ghostty's `SplitTree.spatialNeighbor` behavior.
    fileprivate func nearEdgeLeaf(movingFrom direction: SplitTree.SpatialDirection) -> TerminalID {
        switch self {
        case .leaf(let id):
            return id
        case .split(let s):
            guard s.direction == direction.requiredSplitDirection else {
                // Perpendicular split — reading-order pick.
                return s.left.nearEdgeLeaf(movingFrom: direction)
            }
            switch direction {
            case .right, .down:
                return s.left.nearEdgeLeaf(movingFrom: direction)
            case .left, .up:
                return s.right.nearEdgeLeaf(movingFrom: direction)
            }
        }
    }

    func inserting(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree.Node {
        switch self {
        case .leaf(let id):
            if id == target {
                return .split(.init(
                    direction: direction,
                    ratio: 0.5,
                    left: .leaf(id),
                    right: .leaf(newLeaf)
                ))
            }
            return self
        case .split(let s):
            return .split(.init(
                direction: s.direction,
                ratio: s.ratio,
                left: s.left.inserting(newLeaf, at: target, direction: direction),
                right: s.right.inserting(newLeaf, at: target, direction: direction)
            ))
        }
    }

    func insertingBefore(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree.Node {
        switch self {
        case .leaf(let id):
            if id == target {
                return .split(.init(
                    direction: direction,
                    ratio: 0.5,
                    left: .leaf(newLeaf),
                    right: .leaf(id)
                ))
            }
            return self
        case .split(let s):
            return .split(.init(
                direction: s.direction,
                ratio: s.ratio,
                left: s.left.insertingBefore(newLeaf, at: target, direction: direction),
                right: s.right.insertingBefore(newLeaf, at: target, direction: direction)
            ))
        }
    }

    func removing(_ target: TerminalID) -> SplitTree.Node? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let s):
            let newLeft = s.left.removing(target)
            let newRight = s.right.removing(target)
            if newLeft == nil { return newRight }
            if newRight == nil { return newLeft }
            return .split(.init(
                direction: s.direction,
                ratio: s.ratio,
                left: newLeft!,
                right: newRight!
            ))
        }
    }

    func position(of terminalID: TerminalID) -> SplitTree.LeafPosition? {
        guard case .split(let s) = self else { return nil }

        // Direct hit: `terminalID` is a leaf one level below. The *other*
        // branch of this split is the sibling — pick its first leaf as an
        // anchor. We prefer a direct match over recursing because the
        // split's direction + left/right tell us exactly where the leaf
        // was placed.
        if case .leaf(let id) = s.left, id == terminalID {
            guard let anchor = s.right.allLeaves.first else { return nil }
            return .init(anchorID: anchor, direction: s.direction, placement: .before)
        }
        if case .leaf(let id) = s.right, id == terminalID {
            guard let anchor = s.left.allLeaves.first else { return nil }
            return .init(anchorID: anchor, direction: s.direction, placement: .after)
        }

        // Not a direct child of this split — recurse into whichever side
        // contains the leaf.
        return s.left.position(of: terminalID) ?? s.right.position(of: terminalID)
    }

    func updatingRatio(
        leftAnchor: TerminalID,
        direction targetDirection: SplitDirection,
        ratio: Double
    ) -> SplitTree.Node {
        switch self {
        case .leaf:
            return self
        case .split(let s):
            // Match: direction matches AND left subtree's first leaf is the
            // anchor. Every split rendered with the same anchor+direction
            // collapses to the same node in practice — ambiguity would
            // only arise from contrived nested left-chains, which the
            // SplitTree construction in our app can't produce.
            if s.direction == targetDirection, s.left.allLeaves.first == leftAnchor {
                return .split(s.withRatio(ratio))
            }
            return .split(.init(
                direction: s.direction,
                ratio: s.ratio,
                left: s.left.updatingRatio(leftAnchor: leftAnchor, direction: targetDirection, ratio: ratio),
                right: s.right.updatingRatio(leftAnchor: leftAnchor, direction: targetDirection, ratio: ratio)
            ))
        }
    }

    func updatingRatio(for target: TerminalID, ratio: Double) -> SplitTree.Node {
        switch self {
        case .leaf:
            return self
        case .split(let s):
            if case .leaf(let leftID) = s.left, leftID == target {
                return .split(s.withRatio(ratio))
            }
            return .split(.init(
                direction: s.direction,
                ratio: s.ratio,
                left: s.left.updatingRatio(for: target, ratio: ratio),
                right: s.right.updatingRatio(for: target, ratio: ratio)
            ))
        }
    }

    func resizingAncestor(
        of leaf: TerminalID,
        orientation: SplitDirection,
        delta: Double
    ) throws -> SplitTree.Node {
        switch self {
        case .leaf:
            throw SplitTree.SplitTreeError.noMatchingAncestor
        case .split(let split):
            let leftContains = split.left.containsLeaf(leaf)
            let rightContains = !leftContains && split.right.containsLeaf(leaf)
            guard leftContains || rightContains else {
                throw SplitTree.SplitTreeError.noMatchingAncestor
            }

            if split.direction == orientation {
                let newRatio = min(0.9, max(0.1, split.ratio + delta))
                return .split(split.withRatio(newRatio))
            }

            if leftContains {
                let newLeft = try split.left.resizingAncestor(of: leaf, orientation: orientation, delta: delta)
                return .split(split.withLeft(newLeft))
            } else {
                let newRight = try split.right.resizingAncestor(of: leaf, orientation: orientation, delta: delta)
                return .split(split.withRight(newRight))
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
            if split.left.containsLeaf(leaf) {
                return split.left.ratioOfSplit(containing: leaf)
            }
            return split.right.ratioOfSplit(containing: leaf)
        }
    }

    func equalizing() -> SplitTree.Node {
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
}
