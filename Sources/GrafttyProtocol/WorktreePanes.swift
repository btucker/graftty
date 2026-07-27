import Foundation

/// Visible state of a worktree on the wire. Same five cases as the
/// server-side `WorktreeState` but without the persistence-only
/// `.creating → .closed` / `.deleting → .closed` coercion: the mobile
/// client wants to render a spinner for in-flight rows the same way
/// the Mac sidebar does.
public enum WorktreeWireState: String, Codable, Sendable, Hashable {
    case closed
    case running
    case stale
    case creating
    case deleting

    /// True iff the row is a transient placeholder mid-flight on the
    /// server (`AddWorktreeFlow` for `.creating`, `DeleteWorktreeFlow`
    /// for `.deleting`). The picker renders a spinner and suppresses
    /// taps / swipe actions for these rows. Mirrors
    /// `WorktreeState.isInFlight` server-side.
    public var isInFlight: Bool {
        self == .creating || self == .deleting
    }

    /// True iff the entry's path corresponds to an actual on-disk
    /// worktree the host's git can inspect. Polling and per-worktree
    /// subprocess work should gate on this — `.creating` placeholders
    /// have no directory yet, `.stale` rows have lost theirs, and
    /// `.deleting` is about to vanish. Mirror of `WorktreeState
    /// .hasOnDiskWorktree` so cross-platform sidebar code can ask the
    /// same question without depending on the server-only enum.
    public var hasOnDiskWorktree: Bool {
        switch self {
        case .closed, .running: return true
        case .stale, .creating, .deleting: return false
        }
    }
}

/// Divergence stats for a worktree, faithful to the Mac sidebar's
/// `WorktreeStats` but trimmed to what the mobile gutter renders
/// (ahead/behind/uncommitted) plus the base ref label for tooltips.
public struct WorktreeWireStats: Codable, Sendable, Hashable {
    public let ahead: Int
    public let behind: Int
    public let hasUncommittedChanges: Bool
    /// Optional line-level detail used by the macOS sidebar gutter. Older
    /// hosts omit these fields; clients keep rendering the compact
    /// ahead/behind/dirty summary in that case.
    public let insertions: Int?
    public let deletions: Int?
    /// Ref label the divergence was measured against. Used in the
    /// tooltip on macOS; iOS may surface it via accessibility or a
    /// long-press affordance.
    public let baseRef: String?

    public init(
        ahead: Int,
        behind: Int,
        hasUncommittedChanges: Bool,
        baseRef: String?,
        insertions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.ahead = ahead
        self.behind = behind
        self.hasUncommittedChanges = hasUncommittedChanges
        self.baseRef = baseRef
        self.insertions = insertions
        self.deletions = deletions
    }

    public var isEmpty: Bool {
        ahead == 0 && behind == 0 && !hasUncommittedChanges
    }
}

/// Identifies the Mac that owns a worktree in an origin-aware snapshot.
///
/// `relayDepth == 0` is always local to the server emitting the snapshot.
/// A server may promote those rows to depth 1 when sharing a directly
/// connected Remote Mac, but rows already carrying a non-zero depth must
/// never be promoted again. That single rule prevents A↔B relay loops.
public struct WorktreeOrigin: Codable, Sendable, Hashable {
    public let deviceID: RemoteDeviceID
    public let deviceLabel: String
    public let relayDepth: Int

    public init(deviceID: RemoteDeviceID, deviceLabel: String, relayDepth: Int) {
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel
        self.relayDepth = max(0, relayDepth)
    }
}

/// Live, opaque route identifiers attached only to relayed rows. They are
/// lookup keys, not encoded filesystem paths or zmx names: hosts must resolve
/// them against their current route table and reject unknown values.
public struct WorktreeRoute: Codable, Sendable, Hashable {
    public let repositoryID: String
    public let worktreeID: String

    public init(repositoryID: String, worktreeID: String) {
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
    }
}

/// One entry per worktree. Dual role:
///   1. **Wire format** served by `GET /worktrees/panes` — the mobile
///      client decodes these to render a remote sidebar mirror.
///   2. **Shared sidebar row model.** Every field a worktree row needs
///      to display (state, displayName, displayBranch, isMainCheckout,
///      prBadge, stats with baseRef, attentionText, pane layout) lives
///      here, so both the Mac sidebar and the iPad sidebar can flatten
///      onto the same shape. The Mac server-side projection at
///      `GrafttyApp.swift`'s `setWorktreePanesProvider` builds this
///      from `RepoEntry` + `WorktreeEntry` + the various stat / PR /
///      attention stores; the iPad consumes it directly from the wire.
///
/// `WorktreeWireStats` carries the line-level details needed by the macOS
/// `WorktreeRow`, allowing relayed rows to use the same presentation
/// component without reconstructing filesystem-backed state locally.
public struct WorktreePanes: Codable, Sendable, Hashable {
    public let path: String
    public let displayName: String
    public let repoDisplayName: String
    /// Opaque identity of the owning repository. New hosts populate this
    /// with their canonical repository token; nil preserves compatibility
    /// with older snapshots that exposed only `repoDisplayName`.
    public let repositoryID: String?
    /// Branch name, sanitized of bidirectional-override scalars so
    /// the mobile client can render it directly without re-running
    /// the Trojan-Source defense (`GIT-2.10`).
    public let displayBranch: String
    public let state: WorktreeWireState
    /// True when this entry is the repo's main checkout
    /// (`worktree.path == repo.path`). Drives the italic + house-icon
    /// distinction on both platforms.
    public let isMainCheckout: Bool
    /// PR/MR snapshot for the worktree, when one is associated.
    public let prBadge: PRBadge?
    /// Divergence stats vs. the worktree's upstream refs.
    public let stats: WorktreeWireStats?
    /// Worktree-scoped attention text (the body of `graftty notify`).
    /// Rendered as a red capsule next to the branch label. nil when
    /// there is no active worktree-scoped ping.
    public let attentionText: String?
    /// Source of worktree-scoped attention. Optional for compatibility with
    /// older hosts; consumers conservatively treat a missing source as a
    /// user notification.
    public let attentionSource: AttentionSource?
    /// nil when the worktree has no panes currently running. Always
    /// nil for worktrees in `.closed`, `.stale`, or `.creating`.
    public let layout: PaneLayoutNode?
    /// nil for legacy snapshots. New origin-aware snapshots identify their
    /// owning Mac explicitly, including local rows (`relayDepth == 0`).
    public let origin: WorktreeOrigin?
    /// Present only for rows relayed through another Mac.
    public let route: WorktreeRoute?

    public init(
        path: String,
        displayName: String,
        repoDisplayName: String,
        repositoryID: String? = nil,
        displayBranch: String,
        state: WorktreeWireState,
        isMainCheckout: Bool,
        prBadge: PRBadge?,
        stats: WorktreeWireStats?,
        attentionText: String?,
        attentionSource: AttentionSource? = nil,
        layout: PaneLayoutNode?,
        origin: WorktreeOrigin? = nil,
        route: WorktreeRoute? = nil
    ) {
        self.path = path
        self.displayName = displayName
        self.repoDisplayName = repoDisplayName
        self.repositoryID = repositoryID
        self.displayBranch = displayBranch
        self.state = state
        self.isMainCheckout = isMainCheckout
        self.prBadge = prBadge
        self.stats = stats
        self.attentionText = attentionText
        self.attentionSource = attentionSource
        self.layout = layout
        self.origin = origin
        self.route = route
    }

    /// Custom decode preserves readability when an older server
    /// serves the pre-sidebar-mirror shape (path/displayName/
    /// repoDisplayName/layout only): missing fields fall back to
    /// safe defaults rather than failing the decode.
    private enum CodingKeys: String, CodingKey {
        case path, displayName, repoDisplayName, repositoryID, displayBranch, state,
             isMainCheckout, prBadge, stats, attentionText, attentionSource,
             layout, origin, route
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.repoDisplayName = try c.decode(String.self, forKey: .repoDisplayName)
        self.repositoryID = try c.decodeIfPresent(
            String.self,
            forKey: .repositoryID
        )
        self.displayBranch = try c.decodeIfPresent(String.self, forKey: .displayBranch) ?? ""
        self.state = try c.decodeIfPresent(WorktreeWireState.self, forKey: .state) ?? .running
        self.isMainCheckout = try c.decodeIfPresent(Bool.self, forKey: .isMainCheckout) ?? false
        self.prBadge = try c.decodeIfPresent(PRBadge.self, forKey: .prBadge)
        self.stats = try c.decodeIfPresent(WorktreeWireStats.self, forKey: .stats)
        self.attentionText = try c.decodeIfPresent(String.self, forKey: .attentionText)
        self.attentionSource = try c.decodeIfPresent(
            AttentionSource.self,
            forKey: .attentionSource
        )
        self.layout = try c.decodeIfPresent(PaneLayoutNode.self, forKey: .layout)
        self.origin = try c.decodeIfPresent(WorktreeOrigin.self, forKey: .origin)
        self.route = try c.decodeIfPresent(WorktreeRoute.self, forKey: .route)
    }
}

/// The split-tree of panes inside a worktree, faithful to the Mac
/// sidebar's tree. Leaves carry the zmx `sessionName` (for `/ws?session=`),
/// the current pane title, and an optional pane-scoped attention text;
/// splits carry direction + ratio + children.
///
/// Wire format uses a `"kind"` discriminator so the JSON is stable across
/// Swift changes to indirect-enum Codable synthesis:
///   - leaf:  `{"kind":"leaf","sessionName":"…","title":"…","attentionText":"…"?,"isBusy":true?,"attentionSource":"…"?}`
///           (`isBusy` is omitted from the JSON when false, so idle leaves
///           keep their compact shape and legacy decoders are unaffected.
///           `attentionSource` is likewise optional — absent when the pane
///           has no attention or the source is unknown — so legacy decoders
///           that predate it still decode cleanly.)
///   - split: `{"kind":"split","direction":"horizontal","ratio":0.5,
///             "left":{…},"right":{…}}`
public indirect enum PaneLayoutNode: Sendable, Hashable {
    case leaf(sessionName: String, title: String, attentionText: String?, isBusy: Bool, attentionSource: AttentionSource?)
    case split(direction: SplitAxis, ratio: Double, left: PaneLayoutNode, right: PaneLayoutNode)

    public enum SplitAxis: String, Codable, Sendable, Hashable {
        case horizontal
        case vertical
    }

    public struct Leaf: Sendable, Hashable {
        public let sessionName: String
        public let title: String
        public let attentionText: String?
        /// True while this pane's claude session is busy (AGENT-2.2).
        /// Renderers tint the title green rather than showing a capsule.
        public let isBusy: Bool
        /// Source of this pane's attention, when one is active. Lets the
        /// iPad renderer show a distinct icon for agent-stop "needs input"
        /// (`.agentStop`) versus other attention sources. nil when the pane
        /// has no attention or the source is unknown.
        public let attentionSource: AttentionSource?

        /// Falls back to the literal `"shell"` when the libghostty
        /// `SET_TITLE` action hasn't fired yet. Centralizing the
        /// fallback string lets every renderer (Mac sidebar, mobile
        /// picker, fullscreen tab title) agree on the same empty-state
        /// label without each one re-spelling the rule.
        public var displayTitle: String {
            title.isEmpty ? "shell" : title
        }
    }

    public var isLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }

    /// In-order walk of the tree, returning every leaf left-to-right.
    /// Mirrors how the Mac sidebar's `splitTree.allLeaves` flattens a
    /// pane tree: split direction/ratio is geometry for the detail
    /// view, irrelevant when listing leaves.
    public var leaves: [Leaf] {
        var out: [Leaf] = []
        collectLeaves(into: &out)
        return out
    }

    private func collectLeaves(into out: inout [Leaf]) {
        switch self {
        case let .leaf(sessionName, title, attentionText, isBusy, attentionSource):
            out.append(Leaf(sessionName: sessionName, title: title,
                            attentionText: attentionText, isBusy: isBusy,
                            attentionSource: attentionSource))
        case let .split(_, _, left, right):
            left.collectLeaves(into: &out)
            right.collectLeaves(into: &out)
        }
    }
}

extension PaneLayoutNode: Codable {
    private enum Kind: String, Codable {
        case leaf
        case split
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sessionName, title, attentionText, isBusy, attentionSource, direction, ratio, left, right
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .leaf:
            self = .leaf(
                sessionName: try c.decode(String.self, forKey: .sessionName),
                title: try c.decode(String.self, forKey: .title),
                attentionText: try c.decodeIfPresent(String.self, forKey: .attentionText),
                isBusy: try c.decodeIfPresent(Bool.self, forKey: .isBusy) ?? false,
                attentionSource: try c.decodeIfPresent(AttentionSource.self, forKey: .attentionSource)
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
        case let .leaf(sessionName, title, attentionText, isBusy, attentionSource):
            try c.encode(Kind.leaf, forKey: .kind)
            try c.encode(sessionName, forKey: .sessionName)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(attentionText, forKey: .attentionText)
            if isBusy { try c.encode(true, forKey: .isBusy) }
            try c.encodeIfPresent(attentionSource, forKey: .attentionSource)
        case let .split(direction, ratio, left, right):
            try c.encode(Kind.split, forKey: .kind)
            try c.encode(direction, forKey: .direction)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(left, forKey: .left)
            try c.encode(right, forKey: .right)
        }
    }
}
