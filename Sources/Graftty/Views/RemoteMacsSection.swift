import SwiftUI
import GrafttyKit
import GrafttyProtocol

struct RemoteMacsSidebarProjection: Equatable {
    enum Action: Equatable {
        case addRemoteMac
    }

    enum RowLevel: Equatable {
        case remoteMac
        case worktree
        case pane
    }

    struct Row: Identifiable, Equatable {
        enum ID: Hashable {
            case remoteMac(RemoteMacIdentity)
            case worktree(RemoteMacIdentity, String)
            case pane(RemoteMacIdentity, String, String)
        }

        let id: ID
        var remoteIdentity: RemoteMacIdentity
        var worktreePath: String?
        var sessionName: String?
        var level: RowLevel
        var title: String
        var subtitle: String?
        var connectionState: RemoteMacConnectionState
        var isSelected: Bool
    }

    var title: String
    var rows: [Row]
    var addAction: Action

    var isVisible: Bool {
        true
    }

    static func make(
        savedRemoteMacs: [RemoteMac],
        discoveryCandidates _: [GrafttyBonjourCandidate],
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]] = [:],
        selectedRemoteIdentity: RemoteMacIdentity?,
        selectedRemoteWorktreePath: String? = nil,
        selectedRemotePaneSessionName: String? = nil,
        connectionState: (RemoteMacIdentity) -> RemoteMacConnectionState
    ) -> RemoteMacsSidebarProjection {
        let rows = savedRemoteMacs.flatMap { remoteMac -> [Row] in
            let identity = RemoteMacIdentity(remoteMac)
            var rows = [
                Row(
                    id: .remoteMac(identity),
                    remoteIdentity: identity,
                    worktreePath: nil,
                    sessionName: nil,
                    level: .remoteMac,
                    title: remoteMac.label,
                    subtitle: remoteMac.lastKnownBaseURL?.host,
                    connectionState: connectionState(identity),
                    isSelected: selectedRemoteIdentity == identity
                        && selectedRemoteWorktreePath == nil
                        && selectedRemotePaneSessionName == nil
                )
            ]

            for worktree in worktreePanesByRemote[identity] ?? [] {
                rows.append(
                    Row(
                        id: .worktree(identity, worktree.path),
                        remoteIdentity: identity,
                        worktreePath: worktree.path,
                        sessionName: nil,
                        level: .worktree,
                        title: worktree.displayName,
                        subtitle: worktree.displayBranch.isEmpty ? nil : worktree.displayBranch,
                        connectionState: connectionState(identity),
                        isSelected: selectedRemoteIdentity == identity
                            && selectedRemoteWorktreePath == worktree.path
                            && selectedRemotePaneSessionName == nil
                    )
                )

                for leaf in worktree.layout?.leaves ?? [] {
                    rows.append(
                        Row(
                            id: .pane(identity, worktree.path, leaf.sessionName),
                            remoteIdentity: identity,
                            worktreePath: worktree.path,
                            sessionName: leaf.sessionName,
                            level: .pane,
                            title: leaf.displayTitle,
                            subtitle: nil,
                            connectionState: connectionState(identity),
                            isSelected: selectedRemoteIdentity == identity
                                && selectedRemoteWorktreePath == worktree.path
                                && selectedRemotePaneSessionName == leaf.sessionName
                        )
                    )
                }
            }

            return rows
        }
        return RemoteMacsSidebarProjection(
            title: "Remote Macs",
            rows: rows,
            addAction: .addRemoteMac
        )
    }
}

struct RemoteMacSidebarSelection: Equatable {
    var identity: RemoteMacIdentity
    var worktreePath: String?
    var paneSessionName: String?
}

struct RemoteMacSidebarSelectionState: Equatable {
    var selectedWorktreePath: String? = nil
    var selectedRemoteIdentity: RemoteMacIdentity? = nil
    var selectedRemoteWorktreePath: String? = nil
    var selectedRemotePaneSessionName: String? = nil
}

enum RemoteMacSidebarSelectionReducer {
    static func selectRemote(
        _ identity: RemoteMacIdentity,
        state: inout RemoteMacSidebarSelectionState
    ) {
        state.selectedWorktreePath = nil
        state.selectedRemoteIdentity = identity
        state.selectedRemoteWorktreePath = nil
        state.selectedRemotePaneSessionName = nil
    }

    static func selectRemoteWorktree(
        _ identity: RemoteMacIdentity,
        worktreePath: String,
        state: inout RemoteMacSidebarSelectionState
    ) {
        state.selectedWorktreePath = nil
        state.selectedRemoteIdentity = identity
        state.selectedRemoteWorktreePath = worktreePath
        state.selectedRemotePaneSessionName = nil
    }

    static func selectRemotePane(
        _ identity: RemoteMacIdentity,
        worktreePath: String,
        sessionName: String,
        state: inout RemoteMacSidebarSelectionState
    ) {
        state.selectedWorktreePath = nil
        state.selectedRemoteIdentity = identity
        state.selectedRemoteWorktreePath = worktreePath
        state.selectedRemotePaneSessionName = sessionName
    }

    static func selectLocalWorktree(
        _ path: String,
        state: inout RemoteMacSidebarSelectionState
    ) {
        state.selectedWorktreePath = path
        state.selectedRemoteIdentity = nil
        state.selectedRemoteWorktreePath = nil
        state.selectedRemotePaneSessionName = nil
    }

    static func reconcileRemoteSelection(
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]],
        state: inout RemoteMacSidebarSelectionState
    ) {
        guard
            let identity = state.selectedRemoteIdentity,
            let worktreePath = state.selectedRemoteWorktreePath
        else {
            return
        }

        guard
            let worktree = worktreePanesByRemote[identity]?.first(where: { $0.path == worktreePath })
        else {
            state.selectedRemoteWorktreePath = nil
            state.selectedRemotePaneSessionName = nil
            return
        }

        if let sessionName = state.selectedRemotePaneSessionName,
           worktree.layout?.leaves.contains(where: { $0.sessionName == sessionName }) != true {
            state.selectedRemotePaneSessionName = nil
        }
    }
}

/// @spec REMOTE-13.8: While a Remote Mac is connected, the sidebar shall
/// render Mac → repository → worktree → pane hierarchy using the same
/// WorktreeRow and PaneTitleRow presentation components as local worktrees.
struct RemoteMacsSection: View {
    @ObservedObject var model: RemoteMacsModel
    var worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]] = [:]
    let selectedRemoteIdentity: RemoteMacIdentity?
    var selectedRemoteWorktreePath: String?
    var selectedRemotePaneSessionName: String?
    let theme: GhosttyTheme
    let onSelectRemoteMac: (RemoteMac) -> Void
    var onSelectRemoteWorktree: (RemoteMac, String) -> Void = { _, _ in }
    var onSelectRemotePane: (RemoteMac, String, String) -> Void = { _, _, _ in }
    var onAddRemoteWorktree: (RemoteMac, RemoteRepositoryInfo) -> Void = {
        _, _ in
    }
    var onDeleteRemoteWorktree: (RemoteMac, WorktreePanes) -> Void = {
        _, _ in
    }
    let onAddRemoteMac: () -> Void
    @State private var collapsedRemoteMacs: Set<RemoteMacIdentity> = []
    @State private var collapsedRepositories: Set<RemoteRepositoryKey> = []

    private struct RemoteRepositoryKey: Hashable {
        let identity: RemoteMacIdentity
        let id: String
    }

    private var projection: RemoteMacsSidebarProjection {
        RemoteMacsSidebarProjection.make(
            savedRemoteMacs: model.savedRemoteMacs,
            discoveryCandidates: model.discoveryCandidates,
            worktreePanesByRemote: worktreePanesByRemote,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName,
            connectionState: { model.connectionState(for: $0) }
        )
    }

    var body: some View {
        Section {
            ForEach(model.savedRemoteMacs) { remoteMac in
                remoteMacGroup(remoteMac)
            }

            Button(action: onAddRemoteMac) {
                Label("Add Remote Mac...", systemImage: "plus")
                    .foregroundColor(theme.sidebarPrimaryText(isActive: false))
            }
            .buttonStyle(.plain)
            .help("Add Remote Mac")
        } header: {
            Text(projection.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func remoteMacGroup(_ remoteMac: RemoteMac) -> some View {
        let identity = RemoteMacIdentity(remoteMac)
        DisclosureGroup(
            isExpanded: Binding(
                get: { !collapsedRemoteMacs.contains(identity) },
                set: { expanded in
                    if expanded {
                        collapsedRemoteMacs.remove(identity)
                    } else {
                        collapsedRemoteMacs.insert(identity)
                    }
                }
            )
        ) {
            ForEach(groupedRepositories(for: identity), id: \.id) { repository in
                repositoryGroup(
                    repository,
                    worktrees: repository.worktrees,
                    remoteMac: remoteMac
                )
            }
        } label: {
            Button {
                onSelectRemoteMac(remoteMac)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: model.connectionState(for: identity)))
                        .foregroundStyle(iconColor(for: model.connectionState(for: identity)))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(remoteMac.label)
                            .lineLimit(1)
                            .foregroundColor(theme.sidebarPrimaryText(
                                isActive: selectedRemoteIdentity == identity
                                    && selectedRemoteWorktreePath == nil
                            ))
                        if let host = remoteMac.lastKnownBaseURL?.host {
                            Text(host)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func repositoryGroup(
        _ repositoryGroup: RemoteRepositoryGroup,
        worktrees: [WorktreePanes],
        remoteMac: RemoteMac
    ) -> some View {
        let identity = RemoteMacIdentity(remoteMac)
        let key = RemoteRepositoryKey(
            identity: identity,
            id: repositoryGroup.id
        )
        DisclosureGroup(
            isExpanded: Binding(
                get: { !collapsedRepositories.contains(key) },
                set: { expanded in
                    if expanded {
                        collapsedRepositories.remove(key)
                    } else {
                        collapsedRepositories.insert(key)
                    }
                }
            )
        ) {
            ForEach(worktrees, id: \.path) { worktree in
                remoteWorktreeBlock(worktree, remoteMac: remoteMac)
                    .listRowInsets(
                        EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0)
                    )
            }
        } label: {
            HStack(spacing: 6) {
                Text(repositoryGroup.displayName)
                    .foregroundColor(theme.foreground)
                    .fontWeight(.semibold)
                Spacer()
                if let repository = model.repositoriesByRemote[identity]?
                    .first(where: { $0.id == repositoryGroup.id }) {
                    Button {
                        onAddRemoteWorktree(remoteMac, repository)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.sidebarDimIcon)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(
                        "Add worktree to \(repositoryGroup.displayName) on \(remoteMac.label)"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func remoteWorktreeBlock(
        _ worktree: WorktreePanes,
        remoteMac: RemoteMac
    ) -> some View {
        let identity = RemoteMacIdentity(remoteMac)
        let isActive = selectedRemoteIdentity == identity
            && selectedRemoteWorktreePath == worktree.path
        VStack(spacing: 0) {
            Button {
                onSelectRemoteWorktree(remoteMac, worktree.path)
            } label: {
                WorktreeRow(
                    entry: sidebarEntry(for: worktree),
                    isActive: isActive,
                    displayName: worktree.displayName,
                    isMainCheckout: worktree.isMainCheckout,
                    theme: theme,
                    stats: sidebarStats(for: worktree),
                    baseRef: worktree.stats?.baseRef,
                    prBadge: worktree.prBadge,
                    attentionStyle: worktree.attentionText.map {
                        AttentionCapsuleStyle.from(text: $0, source: .userNotify)
                    }
                )
            }
            .buttonStyle(.plain)
            .rightClickMenu {
                remoteWorktreeMenu(worktree, remoteMac: remoteMac)
            }

            if let layout = worktree.layout {
                ForEach(layout.leaves, id: \.sessionName) { leaf in
                    Button {
                        onSelectRemotePane(
                            remoteMac,
                            worktree.path,
                            leaf.sessionName
                        )
                    } label: {
                        PaneTitleRow(
                            title: leaf.title,
                            isActiveWorktree: isActive,
                            isFocusedPane: isActive
                                && selectedRemotePaneSessionName == leaf.sessionName,
                            isBusy: leaf.isBusy,
                            theme: theme,
                            attentionStyle: leaf.attentionText.map {
                                AttentionCapsuleStyle.from(
                                    text: $0,
                                    source: leaf.attentionSource
                                )
                            },
                            portBindings: []
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? theme.foreground.opacity(0.16) : .clear)
        )
    }

    private func groupedRepositories(
        for identity: RemoteMacIdentity
    ) -> [RemoteRepositoryGroup] {
        var order: [String] = []
        var groups: [String: [WorktreePanes]] = [:]
        var displayNames: [String: String] = [:]
        for worktree in worktreePanesByRemote[identity] ?? [] {
            // A direct Remote Mac may publish its own one-hop entries through
            // V2. The desktop subtree intentionally shows only that Mac's
            // local rows.
            guard worktree.origin?.relayDepth ?? 0 == 0 else { continue }
            let repositoryID = worktree.repositoryID
                ?? "legacy:\(worktree.repoDisplayName)"
            if groups[repositoryID] == nil {
                order.append(repositoryID)
                displayNames[repositoryID] = worktree.repoDisplayName
            }
            groups[repositoryID, default: []].append(worktree)
        }
        return order.map {
            RemoteRepositoryGroup(
                id: $0,
                displayName: displayNames[$0] ?? $0,
                worktrees: groups[$0] ?? []
            )
        }
    }

    private struct RemoteRepositoryGroup {
        let id: String
        let displayName: String
        let worktrees: [WorktreePanes]
    }

    private func sidebarEntry(for worktree: WorktreePanes) -> WorktreeEntry {
        WorktreeEntry(
            path: worktree.path,
            branch: worktree.displayBranch,
            state: WorktreeState(worktree.state)
        )
    }

    private func sidebarStats(for worktree: WorktreePanes) -> WorktreeStats? {
        worktree.stats.map {
            WorktreeStats(
                ahead: $0.ahead,
                behind: $0.behind,
                insertions: $0.insertions ?? 0,
                deletions: $0.deletions ?? 0,
                hasUncommittedChanges: $0.hasUncommittedChanges
            )
        }
    }

    private func remoteWorktreeMenu(
        _ worktree: WorktreePanes,
        remoteMac: RemoteMac
    ) -> NSMenu {
        let menu = NSMenu()
        guard !worktree.isMainCheckout, !worktree.state.isInFlight else {
            return menu
        }
        menu.addItem(ClosureMenuItem(
            title: worktree.state == .stale
                ? "Dismiss"
                : "Delete Worktree"
        ) {
            onDeleteRemoteWorktree(remoteMac, worktree)
        })
        return menu
    }

    private func iconName(for state: RemoteMacConnectionState) -> String {
        switch state {
        case .offline:
            "laptopcomputer"
        case .discovered:
            "wifi"
        case .connecting:
            "arrow.triangle.2.circlepath"
        case .connected:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle"
        case .needsPairing:
            "key"
        }
    }

    private func iconColor(for state: RemoteMacConnectionState) -> Color {
        switch state {
        case .connected, .discovered:
            .green
        case .connecting:
            .accentColor
        case .failed, .needsPairing:
            .orange
        case .offline:
            .secondary
        }
    }
}

private extension WorktreeState {
    init(_ state: WorktreeWireState) {
        switch state {
        case .closed: self = .closed
        case .running: self = .running
        case .stale: self = .stale
        case .creating: self = .creating
        case .deleting: self = .deleting
        }
    }
}
