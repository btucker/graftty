import Foundation
import GrafttyProtocol

/// Per-host sources for projecting one `WorktreeEntry` onto the shared
/// `WorktreePanes` row. Each host (Mac web/SSH snapshot, Mac sidebar, Linux
/// headless host) owns different live stores, so it supplies what it has here
/// and `WorktreePanes(entry:repo:inputs:)` does the rest. Differences between
/// hosts are explicit fields rather than divergent hand-written builders.
public struct WorktreeRowInputs {
    /// Owning Mac / host. Local rows use `relayDepth == 0`.
    public var origin: WorktreeOrigin?
    /// Host-scoped project identity; `SidebarWorktreeMetadata.id` derives from
    /// it, so it must stay stable per host. The Mac uses
    /// `"<deviceID>:<repo UUID>"`; the headless host uses the repository path
    /// (matching `HostProjectIcons`).
    public var projectID: String
    public var displayName: String
    /// Virtual folder ancestry for the row; nil publishes no folders.
    public var folders: [SidebarWorktreeHierarchy.Folder]?
    public var prBadge: PRBadge?
    /// Divergence stats. Dropped for entries without an on-disk worktree
    /// (`.stale`, `.creating`, `.deleting`) so a cached value never outlives
    /// its checkout.
    public var stats: WorktreeWireStats?
    /// Rendered pane titles; panes without one publish `""`, and renderers
    /// apply `PaneLayoutNode.Leaf.displayTitle`.
    public var paneTitles: [PaneSlotID: String]
    /// Agent liveness keyed by zmx session name.
    public var liveness: [String: AgentLiveness]
    /// The Mac sidebar's local rows keep a stopped worktree's saved layout
    /// (the split tree survives Stop, `STATE-2.11`). Published snapshots send
    /// layouts only for running worktrees, because remote clients attach to
    /// a leaf's session and a stopped worktree has none.
    public var includeLayoutWhenStopped: Bool
    public var ports: [WorktreePort]
    public var portBindings: [String: [PortBinding]]?

    public init(
        origin: WorktreeOrigin?,
        projectID: String,
        displayName: String,
        folders: [SidebarWorktreeHierarchy.Folder]? = nil,
        prBadge: PRBadge? = nil,
        stats: WorktreeWireStats? = nil,
        paneTitles: [PaneSlotID: String] = [:],
        liveness: [String: AgentLiveness] = [:],
        includeLayoutWhenStopped: Bool = false,
        ports: [WorktreePort] = [],
        portBindings: [String: [PortBinding]]? = nil
    ) {
        self.origin = origin
        self.projectID = projectID
        self.displayName = displayName
        self.folders = folders
        self.prBadge = prBadge
        self.stats = stats
        self.paneTitles = paneTitles
        self.liveness = liveness
        self.includeLayoutWhenStopped = includeLayoutWhenStopped
        self.ports = ports
        self.portBindings = portBindings
    }
}

extension WorktreePanes {
    /// The single `WorktreeEntry → WorktreePanes` projection shared by every host.
    public init(entry: WorktreeEntry, repo: RepoEntry, inputs: WorktreeRowInputs) {
        let layoutRoot = entry.state == .running || inputs.includeLayoutWhenStopped ? entry.splitTree.root : nil
        var resultBudget = 32 * 1024
        let agentSummaries = entry.agents.map { agent in
            let result = resultBudget > 0 ? agent.completion.map { AgentTextPreview.prefix($0.result, bytes: min(1024, resultBudget)) } : nil
            resultBudget -= result?.utf8.count ?? 0
            let previous = agent.results.suffix(5).filter { $0.id != agent.completion?.id }.suffix(4).map { record in
                let preview = AgentTextPreview.prefix(record.result, bytes: min(256, resultBudget))
                resultBudget -= preview.utf8.count
                return preview
            }
            return AgentSessionInfo(id: agent.id, name: AgentTextPreview.prefix(agent.name, bytes: 256), provider: agent.provider.rawValue,
                status: agent.status.rawValue,
                sessionName: agent.status == .closed ? nil : agent.paneSlotID.flatMap { entry.paneSessions[$0] }.map(ZmxLauncher.sessionName(for:)),
                assignmentID: agent.assignmentID.uuidString, completionID: agent.completion?.id.uuidString,
                result: result, previousResults: previous, failure: agent.failure.map { AgentTextPreview.prefix($0, bytes: 1024) },
                processObservation: agent.processObservation, outcome: agent.completion?.outcome?.rawValue,
                resultCount: agent.results.count, resultsAreSummaries: true,
                retainedSessionName: agent.paneSessionID.map(ZmxLauncher.sessionName(for:)),
                retainedSlotID: agent.presentationSlotID?.id.uuidString,
                canResume: agent.providerSessionID?.isEmpty == false && agent.completion != nil && agent.status != .closing,
                transcriptRevision: agent.transcriptArchive?.id)
        }
        self.init(
            path: entry.path,
            displayName: inputs.displayName,
            repoDisplayName: repo.displayName,
            repositoryID: repo.path,
            displayBranch: entry.displayBranch,
            state: entry.state.wireState,
            isMainCheckout: entry.path == repo.path,
            prBadge: inputs.prBadge,
            stats: entry.state.hasOnDiskWorktree ? inputs.stats : nil,
            attentionText: entry.attention?.text,
            attentionSource: entry.attention?.source,
            attentionTimestamp: entry.attention?.timestamp,
            layout: layoutRoot?.wireLayout(sessions: entry.paneSessions, titles: inputs.paneTitles,
                                           attention: entry.paneAttention, liveness: inputs.liveness),
            origin: inputs.origin,
            sidebar: SidebarHostNavigation.metadata(
                for: entry, projectID: inputs.projectID, folders: inputs.folders?.map(\.name) ?? [],
                repositoryPath: repo.path, folderIDs: inputs.folders?.map(\.id)),
            ports: inputs.ports,
            portBindings: inputs.portBindings,
            creationProgress: entry.creationProgress,
            agents: agentSummaries
        )
    }
}

extension SplitTree.Node {
    /// Wire form of a pane tree. Leaves carry the zmx session name (`""` for a
    /// slot with no session yet), the rendered title (`""` when none), the
    /// pane-scoped attention, and liveness-derived busy state.
    public func wireLayout(
        sessions: [PaneSlotID: PaneSessionID],
        titles: [PaneSlotID: String],
        attention: [PaneSlotID: Attention],
        liveness: [String: AgentLiveness]
    ) -> PaneLayoutNode {
        switch self {
        case .leaf(let slot):
            let sessionName = sessions[slot].map(ZmxLauncher.sessionName(for:))
            let paneAttention = attention[slot]
            return .leaf(
                sessionName: sessionName ?? "",
                title: titles[slot] ?? "",
                attentionText: paneAttention?.text,
                isBusy: AgentLivenessMerge.isPaneBusy(sessionName: sessionName, liveness: liveness),
                attentionSource: paneAttention?.source,
                attentionTimestamp: paneAttention?.timestamp
            )
        case .split(let split):
            return .split(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio,
                left: split.left.wireLayout(sessions: sessions, titles: titles, attention: attention, liveness: liveness),
                right: split.right.wireLayout(sessions: sessions, titles: titles, attention: attention, liveness: liveness)
            )
        }
    }
}
