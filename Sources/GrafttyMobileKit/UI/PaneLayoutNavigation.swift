#if canImport(UIKit)
import GrafttyProtocol

public enum PaneLayoutNavigation {
    public enum Direction: CaseIterable, Sendable {
        case left
        case right
        case up
        case down

        fileprivate var requiredSplitAxis: PaneLayoutNode.SplitAxis {
            switch self {
            case .left, .right:
                return .horizontal
            case .up, .down:
                return .vertical
            }
        }

        fileprivate var sourceSide: SubtreeSide {
            switch self {
            case .right, .down:
                return .left
            case .left, .up:
                return .right
            }
        }
    }

    fileprivate enum SubtreeSide {
        case left
        case right
    }

    public static func spatialNeighbor(
        in root: PaneLayoutNode,
        of sessionName: String,
        direction: Direction,
        excluding excludedSessionNames: Set<String> = []
    ) -> String? {
        guard let projectedRoot = root.removingLeaves(
            named: excludedSessionNames
        ) else {
            return nil
        }
        return projectedRoot.findSpatialNeighbor(
            of: sessionName,
            direction: direction
        )
    }

    public static func nextInOrder(
        in root: PaneLayoutNode,
        from sessionName: String,
        forward: Bool,
        excluding excludedSessionNames: Set<String> = []
    ) -> String? {
        guard let projectedRoot = root.removingLeaves(
            named: excludedSessionNames
        ) else {
            return nil
        }
        let leaves = projectedRoot.leaves.map(\.sessionName)
        guard leaves.count > 1,
              let index = leaves.firstIndex(of: sessionName) else {
            return nil
        }
        let nextIndex = forward
            ? (index + 1) % leaves.count
            : (index - 1 + leaves.count) % leaves.count
        return leaves[nextIndex]
    }
}

private extension PaneLayoutNode {
    func removingLeaves(named sessionNames: Set<String>) -> PaneLayoutNode? {
        guard !sessionNames.isEmpty else { return self }
        switch self {
        case let .leaf(sessionName, _, _, _, _, _):
            return sessionNames.contains(sessionName) ? nil : self
        case let .split(direction, ratio, left, right):
            let projectedLeft = left.removingLeaves(named: sessionNames)
            let projectedRight = right.removingLeaves(named: sessionNames)
            switch (projectedLeft, projectedRight) {
            case let (left?, right?):
                return .split(
                    direction: direction,
                    ratio: ratio,
                    left: left,
                    right: right
                )
            case let (left?, nil):
                return left
            case let (nil, right?):
                return right
            case (nil, nil):
                return nil
            }
        }
    }

    func containsLeaf(sessionName: String) -> Bool {
        switch self {
        case let .leaf(name, _, _, _, _, _):
            return name == sessionName
        case let .split(_, _, left, right):
            return left.containsLeaf(sessionName: sessionName)
                || right.containsLeaf(sessionName: sessionName)
        }
    }

    func findSpatialNeighbor(
        of sessionName: String,
        direction: PaneLayoutNavigation.Direction
    ) -> String? {
        guard case let .split(splitAxis, _, left, right) = self else {
            return nil
        }

        if left.containsLeaf(sessionName: sessionName) {
            if let found = left.findSpatialNeighbor(of: sessionName, direction: direction) {
                return found
            }
            if splitAxis == direction.requiredSplitAxis,
               direction.sourceSide == .left {
                return right.nearEdgeLeaf(movingFrom: direction)
            }
            return nil
        }

        if right.containsLeaf(sessionName: sessionName) {
            if let found = right.findSpatialNeighbor(of: sessionName, direction: direction) {
                return found
            }
            if splitAxis == direction.requiredSplitAxis,
               direction.sourceSide == .right {
                return left.nearEdgeLeaf(movingFrom: direction)
            }
            return nil
        }

        return nil
    }

    func nearEdgeLeaf(movingFrom direction: PaneLayoutNavigation.Direction) -> String {
        switch self {
        case let .leaf(sessionName, _, _, _, _, _):
            return sessionName
        case let .split(splitAxis, _, left, right):
            guard splitAxis == direction.requiredSplitAxis else {
                return left.nearEdgeLeaf(movingFrom: direction)
            }
            switch direction {
            case .right, .down:
                return left.nearEdgeLeaf(movingFrom: direction)
            case .left, .up:
                return right.nearEdgeLeaf(movingFrom: direction)
            }
        }
    }
}
#endif
