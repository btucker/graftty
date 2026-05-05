import Foundation

/// One entry per running worktree, served by `GET /worktrees/panes`. The
/// mobile client uses these to render a worktree picker (first screen)
/// and then the per-worktree pane tree (second screen, split-faithful
/// layout mirroring the Mac sidebar).
public struct WorktreePanes: Codable, Sendable, Hashable {
    public let path: String
    public let displayName: String
    public let repoDisplayName: String
    /// nil when the worktree has no panes currently running. Non-running
    /// worktrees are omitted from the response entirely; a nil layout on
    /// a returned worktree is theoretically possible if the worktree is
    /// in transition, and clients should render it as "no panes yet".
    public let layout: PaneLayoutNode?

    public init(
        path: String,
        displayName: String,
        repoDisplayName: String,
        layout: PaneLayoutNode?
    ) {
        self.path = path
        self.displayName = displayName
        self.repoDisplayName = repoDisplayName
        self.layout = layout
    }
}

/// The split-tree of panes inside a worktree, faithful to the Mac
/// sidebar's tree. Leaves carry the zmx `sessionName` (for `/ws?session=`)
/// and the current pane title; splits carry direction + ratio + children.
///
/// Wire format uses a `"kind"` discriminator so the JSON is stable across
/// Swift changes to indirect-enum Codable synthesis:
///   - leaf:  `{"kind":"leaf","sessionName":"…","title":"…"}`
///   - split: `{"kind":"split","direction":"horizontal","ratio":0.5,
///             "left":{…},"right":{…}}`
public indirect enum PaneLayoutNode: Sendable, Hashable {
    case leaf(sessionName: String, title: String)
    case split(direction: SplitAxis, ratio: Double, left: PaneLayoutNode, right: PaneLayoutNode)

    public enum SplitAxis: String, Codable, Sendable, Hashable {
        case horizontal
        case vertical
    }

    public var isLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }
}

extension PaneLayoutNode: Codable {
    private enum Kind: String, Codable {
        case leaf
        case split
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sessionName, title, direction, ratio, left, right
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .leaf:
            self = .leaf(
                sessionName: try c.decode(String.self, forKey: .sessionName),
                title: try c.decode(String.self, forKey: .title)
            )
        case .split:
            self = .split(
                direction: try c.decode(SplitAxis.self, forKey: .direction),
                ratio: try c.decode(Double.self, forKey: .ratio),
                left: try c.decode(PaneLayoutNode.self, forKey: .left),
                right: try c.decode(PaneLayoutNode.self, forKey: .right)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .leaf(sessionName, title):
            try c.encode(Kind.leaf, forKey: .kind)
            try c.encode(sessionName, forKey: .sessionName)
            try c.encode(title, forKey: .title)
        case let .split(direction, ratio, left, right):
            try c.encode(Kind.split, forKey: .kind)
            try c.encode(direction, forKey: .direction)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(left, forKey: .left)
            try c.encode(right, forKey: .right)
        }
    }
}
