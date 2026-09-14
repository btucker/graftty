import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

enum RemoteWorktreeReorderPolicy {
    static func allows(_ worktree: WorktreePanes, editableProjectIDs: Set<String>, query: String) -> Bool {
        query.isEmpty && !worktree.isMainCheckout && !worktree.state.isInFlight
            && editableProjectIDs.contains(SidebarProjection.projectID(worktree))
    }
}

private struct RemoteWorktreeDragSource: ViewModifier {
    let route: String
    let isEnabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isEnabled { content.draggable("graftty-remote-worktree:" + route) }
        else { content }
    }
}

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

    var projectFilter: String? = nil
    var query: String = ""
    var showsRepositoryHeaders = true
    var editableProjectIDs: Set<String> = []

    var body: some View {
        Section {
            ForEach(model.savedRemoteMacs.filter { mac in
                (projectFilter == nil && query.isEmpty) || (worktreePanesByRemote[RemoteMacIdentity(mac)] ?? []).contains {
                    (projectFilter == nil || SidebarProjection.projectID($0) == projectFilter)
                        && SidebarInteractionPolicy.matches($0, query: query)
                }
            }) { remoteMac in
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
            ForEach(groupedRepositories(for: identity).filter { repository in
                repository.worktrees.contains {
                    (projectFilter == nil || SidebarProjection.projectID($0) == projectFilter)
                        && SidebarInteractionPolicy.matches($0, query: query)
                }
            }, id: \.id) { repository in
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
        let rows = Group {
            SidebarWorktreeRows(worktrees: worktrees.filter {
                (projectFilter == nil || SidebarProjection.projectID($0) == projectFilter)
                    && SidebarInteractionPolicy.matches($0, query: query)
            }) { worktree in
                remoteWorktreeBlock(worktree, remoteMac: remoteMac)
                    .listRowInsets(
                        EdgeInsets(top: 0, leading: showsRepositoryHeaders ? -20 : 0, bottom: 0, trailing: 0)
                    )
            }
        }
        if showsRepositoryHeaders {
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsedRepositories.contains(key) },
                set: { expanded in
                    if expanded { collapsedRepositories.remove(key) }
                    else { collapsedRepositories.insert(key) }
                }
            )) {
                rows
            } label: {
                HStack(spacing: 6) {
                    Text(repositoryGroup.displayName).foregroundColor(theme.foreground).fontWeight(.semibold)
                    Spacer()
                    addWorktreeButton(repositoryGroup, remoteMac: remoteMac, showsLabel: false)
                }
            }
        } else {
            HStack { Spacer(); addWorktreeButton(repositoryGroup, remoteMac: remoteMac, showsLabel: true) }
            rows
        }
    }

    @ViewBuilder
    private func addWorktreeButton(_ group: RemoteRepositoryGroup, remoteMac: RemoteMac, showsLabel: Bool) -> some View {
        if let repository = model.repositoriesByRemote[RemoteMacIdentity(remoteMac)]?.first(where: { $0.id == group.id }) {
            Button { onAddRemoteWorktree(remoteMac, repository) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    if showsLabel { Text("Add worktree") }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.sidebarDimIcon)
                .frame(minWidth: 18, minHeight: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add worktree to \(group.displayName) on \(remoteMac.label)")
            .accessibilityLabel("Add worktree to \(group.displayName) on \(remoteMac.label)")
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
                        AttentionCapsuleStyle.from(
                            text: $0,
                            source: worktree.attentionSource
                        )
                    }
                )
            }
            .buttonStyle(.plain)
            .rightClickMenu {
                remoteWorktreeMenu(worktree, remoteMac: remoteMac)
            }
            .modifier(RemoteWorktreeDragSource(route: worktree.path, isEnabled: canReorder(worktree, on: remoteMac)))
            .dropDestination(for: String.self) { values, location in
                guard query.isEmpty, !worktree.state.isInFlight,
                      editableProjectIDs.contains(SidebarProjection.projectID(worktree)),
                      let value = values.first, value.hasPrefix("graftty-remote-worktree:"),
                      let source = worktreePanesByRemote[identity]?.first(where: { $0.path == String(value.dropFirst("graftty-remote-worktree:".count)) }),
                      canReorder(source, on: remoteMac), source.path != worktree.path,
                      source.repositoryID == worktree.repositoryID,
                      (source.sidebar?.folderIDs ?? source.sidebar?.folders) == (worktree.sidebar?.folderIDs ?? worktree.sidebar?.folders),
                      !worktree.isMainCheckout || location.y > 14 else { return false }
                moveRemoteWorktree(source, relativeTo: worktree, after: location.y > 14, remoteMac: remoteMac)
                return true
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

    private func canReorder(_ worktree: WorktreePanes, on remoteMac: RemoteMac) -> Bool {
        model.connectionState(for: RemoteMacIdentity(remoteMac)) == .connected
            && RemoteWorktreeReorderPolicy.allows(worktree, editableProjectIDs: editableProjectIDs, query: query)
    }

    private func moveRemoteWorktree(_ source: WorktreePanes, relativeTo target: WorktreePanes, after: Bool, remoteMac: RemoteMac) {
        guard canReorder(source, on: remoteMac), !target.state.isInFlight,
              let repositoryID = source.repositoryID else { return }
        Task {
            guard await model.sidebarSnapshot(for: remoteMac)?.supportsNavigationEditing == true else {
                let alert = NSAlert()
                alert.messageText = "Couldn't reorder worktrees"
                alert.informativeText = "The owning Mac no longer advertises worktree editing. Reconnect to a supported version of Graftty."
                alert.runModal()
                return
            }
            do {
                let response = try await model.sendWorktreeManagement(identity: RemoteMacIdentity(remoteMac),
                    request: .moveWorktree(repositoryID: repositoryID, worktreeID: source.path, relativeTo: target.path, after: after))
                if case .error(_, let message, _, _) = response {
                    let alert = NSAlert(); alert.messageText = "Couldn't reorder worktrees"; alert.informativeText = message; alert.runModal()
                }
            } catch {
                let alert = NSAlert(); alert.messageText = "Couldn't reach the owning Mac"; alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
    }

    private func remoteWorktreeMenu(
        _ worktree: WorktreePanes,
        remoteMac: RemoteMac
    ) -> NSMenu {
        let menu = NSMenu()
        let siblings = (worktreePanesByRemote[RemoteMacIdentity(remoteMac)] ?? []).filter {
            $0.repositoryID == worktree.repositoryID && ($0.sidebar?.folderIDs ?? $0.sidebar?.folders) == (worktree.sidebar?.folderIDs ?? worktree.sidebar?.folders)
        }
        if canReorder(worktree, on: remoteMac),
           let index = siblings.firstIndex(where: { $0.path == worktree.path }) {
            if index > 0, !siblings[index - 1].isMainCheckout, !siblings[index - 1].state.isInFlight {
                menu.addItem(ClosureMenuItem(title: "Move Up") { moveRemoteWorktree(worktree, relativeTo: siblings[index - 1], after: false, remoteMac: remoteMac) })
            }
            if index + 1 < siblings.count, !siblings[index + 1].state.isInFlight {
                menu.addItem(ClosureMenuItem(title: "Move Down") { moveRemoteWorktree(worktree, relativeTo: siblings[index + 1], after: true, remoteMac: remoteMac) })
            }
        }

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
