import Foundation

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct SplitTree: Codable, Sendable, Equatable {
    public let root: Node?

    public init(root: Node?) {
        self.root = root
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

    /// Resolve a user-facing 1-based pane ID (as printed by `espalier
    /// pane list`) to its underlying `TerminalID`, or nil if the ID is
    /// out of range. Uses `allLeaves` order — the same order `list`
    /// displays.
    public func leaf(atPaneID paneID: Int) -> TerminalID? {
        let leaves = allLeaves
        let idx = paneID - 1
        guard leaves.indices.contains(idx) else { return nil }
        return leaves[idx]
    }

    // MARK: - Mutations (return new trees)

    public func inserting(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.inserting(newLeaf, at: target, direction: direction))
    }

    /// Like `inserting`, but the new leaf becomes the *left/top* child rather
    /// than the *right/bottom*. Used by "Split Left" / "Split Up" from the
    /// context menu — same split, opposite placement.
    public func insertingBefore(_ newLeaf: TerminalID, at target: TerminalID, direction: SplitDirection) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.insertingBefore(newLeaf, at: target, direction: direction))
    }

    public func removing(_ target: TerminalID) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.removing(target))
    }

    public func updatingRatio(for target: TerminalID, ratio: Double) -> SplitTree {
        guard let root else { return self }
        return SplitTree(root: root.updatingRatio(for: target, ratio: ratio))
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
        return SplitTree(root: root.updatingRatio(leftAnchor: leftAnchor, direction: direction, ratio: ratio))
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
}
