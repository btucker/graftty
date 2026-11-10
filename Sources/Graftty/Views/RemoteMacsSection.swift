import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
import CoreTransferable
import UniformTypeIdentifiers

struct RemoteWorktreeDragPayload: Codable, Transferable {
    static let contentType = UTType(exportedAs: "com.graftty.remote-worktree-move", conformingTo: .data)
    let deviceID: RemoteDeviceID
    let fingerprint: RemoteIdentityFingerprint
    let path: String

    init(identity: RemoteMacIdentity, path: String) {
        self.deviceID = identity.id
        self.fingerprint = identity.fingerprint
        self.path = path
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }

    func resolve(on identity: RemoteMacIdentity, in worktrees: [WorktreePanes]) -> WorktreePanes? {
        guard identity.id == deviceID, identity.fingerprint == fingerprint else { return nil }
        return worktrees.first { $0.path == path }
    }
}

enum RemoteWorktreeReorderPolicy {
    static func allows(_ worktree: WorktreePanes, editableProjectIDs: Set<String>, query: String) -> Bool {
        query.isEmpty && !worktree.isMainCheckout && !worktree.state.isInFlight
            && editableProjectIDs.contains(SidebarProjection.projectID(worktree))
            && isPinned(worktree)
    }

    /// A sleeping host has no connection to check. Dropping the row wakes it.
    static func allowsWhileAsleep(_ worktree: WorktreePanes, query: String) -> Bool {
        query.isEmpty && !worktree.isMainCheckout && !worktree.state.isInFlight && isPinned(worktree)
    }

    static func areSiblings(_ source: WorktreePanes, _ target: WorktreePanes) -> Bool {
        source.repositoryID == target.repositoryID && isPinned(source) == isPinned(target)
    }

    private static func isPinned(_ worktree: WorktreePanes) -> Bool {
        worktree.sidebar?.isPinned == true
            || (worktree.isMainCheckout && worktree.sidebar?.isPinned != nil)
    }
}

private struct RemoteWorktreeDragSource: ViewModifier {
    let payload: RemoteWorktreeDragPayload
    let isEnabled: Bool
    let preview: AnyView
    @State private var rowWidth: CGFloat = 280
    @ViewBuilder func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(payload) { preview.frame(width: rowWidth).fixedSize(horizontal: false, vertical: true) }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        }
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
            title: "Remote Hosts",
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
        let sameWorktree = state.selectedRemoteIdentity == identity && state.selectedRemoteWorktreePath == worktreePath
        state.selectedWorktreePath = nil
        state.selectedRemoteIdentity = identity
        state.selectedRemoteWorktreePath = worktreePath
        if !sameWorktree { state.selectedRemotePaneSessionName = nil }
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

struct RemoteSidebarExpansion {
    struct RepositoryKey: Hashable {
        let identity: RemoteMacIdentity
        let id: String
    }
    var collapsedMacs: Set<RemoteMacIdentity> = []
    var collapsedRepositories: Set<RepositoryKey> = []
}

/// @spec REMOTE-13.8: While a Remote Mac is connected and the project column is disabled, the sidebar shall
/// render Mac → repository → worktree → pane hierarchy using the same
/// WorktreeRow and status line presentation components as local worktrees.
struct RemoteMacsSection: View {
    @ObservedObject var model: RemoteMacsModel
    @Binding var expansion: RemoteSidebarExpansion
    var worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]] = [:]
    let selectedRemoteIdentity: RemoteMacIdentity?
    var selectedRemoteWorktreePath: String?
    var selectedRemotePaneSessionName: String?
    let theme: GhosttyTheme
    let onSelectRemoteMac: (RemoteMac) -> Void
    var onSelectRemoteWorktree: (RemoteMac, String) -> Void = { _, _ in }
    var onAddRemoteWorktree: (RemoteMac, RemoteRepositoryInfo) -> Void = {
        _, _ in
    }
    var onDeleteRemoteWorktree: (RemoteMac, WorktreePanes) -> Void = {
        _, _ in
    }
    let onAddRemoteMac: () -> Void
    var onSetupLinuxHost: (() -> Void)? = nil

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
    var showsMacHierarchy = true
    var showsRepositoryHeaders = true
    var editableProjectIDs: Set<String> = []
    var projects: [SidebarProject] = []
    var projectIcons: [String: Data] = [:]
    var section: SidebarWorktreeSection = .all
    struct SingleRow {
        let worktree: WorktreePanes
        let remoteMac: RemoteMac
        let displayName: String
        let hostLabel: String?
        let isCached: Bool
        /// Draws the pinned agent as a tile in the grid instead of a row.
        var isTile = false
        let onOpen: () -> Void
        /// Clicking a status line that names a pane.
        let onOpenPane: (SidebarWorktreeContext) -> Void
        let onDrop: (WorktreeRowDrop, Bool) -> Bool
    }
    /// Renders one row for the merged sidebar instead of whole sections.
    var singleRow: SingleRow? = nil
    var reportController: SidebarReportController? = nil
    var onDismissRequest: (SidebarWorktreeContext) -> Void = { _ in }
    var contextForWorktree: (WorktreePanes) -> SidebarWorktreeContext = { .init(worktree: $0) }

    @ViewBuilder
    var body: some View {
        if let singleRow, singleRow.isTile {
            remoteTile(singleRow)
        } else if let singleRow {
            remoteWorktreeBlock(singleRow.worktree, remoteMac: singleRow.remoteMac, displayName: singleRow.displayName, hostLabel: singleRow.hostLabel)
        } else if section != .pinned || !displayedRemoteMacs.isEmpty {
            if showsMacHierarchy {
                Section {
                    remoteContents
                } header: {
                    Text(projection.title).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                remoteContents
            }
        }
    }

    private func includes(_ worktree: WorktreePanes) -> Bool {
        (projectFilter == nil || SidebarProjection.projectID(worktree) == projectFilter)
            && contextForWorktree(worktree).matches(query: query)
    }

    private func includesRepository(_ worktrees: [WorktreePanes]) -> Bool {
        let matching = worktrees.filter(includes)
        return !matching.isEmpty && (section != .pinned || SidebarWorktreeSections(matching).hasPinMetadata)
    }

    private var displayedRemoteMacs: [RemoteMac] {
        model.savedRemoteMacs.filter { mac in
            if section != .pinned && projectFilter == nil && query.isEmpty { return true }
            return groupedRepositories(for: RemoteMacIdentity(mac)).contains { includesRepository($0.worktrees) }
        }
    }

    @ViewBuilder
    private var remoteContents: some View {
        ForEach(displayedRemoteMacs) { remoteMac in
            if showsMacHierarchy { remoteMacGroup(remoteMac) }
            else { repositories(for: remoteMac) }
        }

        if showsMacHierarchy && section != .pinned {
            Button(action: onAddRemoteMac) {
                Label("Add Remote Mac...", systemImage: "plus")
                    .foregroundColor(theme.sidebarPrimaryText(isActive: false))
            }
            .buttonStyle(.plain)
            .help("Add Remote Mac")
            if let onSetupLinuxHost {
                Button(action: onSetupLinuxHost) {
                    Label("Set Up Linux Host...", systemImage: "server.rack")
                        .foregroundColor(theme.sidebarPrimaryText(isActive: false))
                }
                .buttonStyle(.plain)
                .help("Install Graftty on an Ubuntu host using OpenSSH")
            }
        }
    }

    @ViewBuilder
    private func remoteMacGroup(_ remoteMac: RemoteMac) -> some View {
        let identity = RemoteMacIdentity(remoteMac)
        DisclosureGroup(
            isExpanded: Binding(
                get: { !expansion.collapsedMacs.contains(identity) },
                set: { expanded in
                    if expanded {
                        expansion.collapsedMacs.remove(identity)
                    } else {
                        expansion.collapsedMacs.insert(identity)
                    }
                }
            )
        ) {
            repositories(for: remoteMac)
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
                        if let failure = model.paneFeedFailure(for: identity) {
                            Text("Worktree feed unavailable").font(.caption).foregroundStyle(.orange).help(failure)
                        } else if let host = remoteMac.lastKnownBaseURL?.host {
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

    private func repositories(for remoteMac: RemoteMac) -> some View {
        ForEach(groupedRepositories(for: RemoteMacIdentity(remoteMac)).filter { repository in
            includesRepository(repository.worktrees)
        }, id: \.id) { repository in
            repositoryGroup(
                repository,
                worktrees: repository.worktrees,
                remoteMac: remoteMac
            )
        }
    }

    @ViewBuilder
    private func repositoryGroup(
        _ repositoryGroup: RemoteRepositoryGroup,
        worktrees: [WorktreePanes],
        remoteMac: RemoteMac
    ) -> some View {
        let identity = RemoteMacIdentity(remoteMac)
        let key = RemoteSidebarExpansion.RepositoryKey(
            identity: identity,
            id: repositoryGroup.id
        )
        let rows = Group {
            SidebarWorktreeRows(worktrees: worktrees.filter(includes), rowInsets: showsMacHierarchy ? EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0) : nil,
               folderIndent: showsMacHierarchy ? 0 : 16, showsSections: query.isEmpty, section: section) { worktree in
                remoteWorktreeBlock(worktree, remoteMac: remoteMac)
                    .listRowInsets(
                        showsMacHierarchy ? EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0) : nil
                    )
                    .listRowSeparator(.hidden)
            }
        }
        if showsRepositoryHeaders {
            DisclosureGroup(isExpanded: Binding(
                get: { !expansion.collapsedRepositories.contains(key) },
                set: { expanded in
                    if expanded { expansion.collapsedRepositories.remove(key) }
                    else { expansion.collapsedRepositories.insert(key) }
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
        remoteMac: RemoteMac,
        displayName: String? = nil,
        hostLabel: String? = nil
    ) -> some View {
        let identity = RemoteMacIdentity(remoteMac)
        let isActive = selectedRemoteIdentity == identity
            && selectedRemoteWorktreePath == worktree.path
        let context = contextForWorktree(worktree)
        let isCached = singleRow?.isCached == true
        let status = SidebarRowStatus.resolve(context: context, worktree: worktree, isCached: isCached)
        let projectID = SidebarProjection.projectID(worktree)
        let project = projects.first { $0.id == projectID }
            ?? SidebarProject(id: projectID, repositoryID: worktree.repositoryID ?? projectID, name: worktree.repoDisplayName)
        let row = WorktreeRow(
            entry: sidebarEntry(for: worktree),
            isActive: isActive,
            displayName: displayName ?? worktree.displayName,
            isMainCheckout: worktree.isMainCheckout,
            theme: theme,
            stats: sidebarStats(for: worktree),
            baseRef: worktree.stats?.baseRef,
            prBadge: worktree.prBadge,
            hostLabel: hostLabel,
            brief: context.brief,
            onRemove: { _ in onDeleteRemoteWorktree(remoteMac, worktree) },
            showsDivergence: false
        )
        let hasDivergence = WorktreeRow.trailingItems(canRemove: row.canRemove).statusLine.contains(.divergence)
            && !(sidebarStats(for: worktree)?.isEmpty ?? true)
        let divergence = hasDivergence ? row.divergence : nil
        let heading = row
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        // DIVERGE-1.1: the status line truncates before the divergence.
        let statusLine = HStack(alignment: .firstTextBaseline, spacing: 6) {
            SidebarStatusLine(status: status, secondary: theme.sidebarSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            divergence
        }
            .padding(.top, SidebarStatusLine.macTopInset)
            .padding(.trailing, 8).padding(.bottom, SidebarStatusLine.macBottomInset(status))
        let identityView = WorktreeRowIdentitySlot(entry: sidebarEntry(for: worktree), displayName: displayName ?? worktree.displayName,
            isMainCheckout: worktree.isMainCheckout, theme: theme, prBadge: worktree.prBadge, status: status,
            project: project, projectIconData: projectIcons[projectID])
        let preview = AnyView(
            SidebarWorktreeRowLayout { identityView } content: {
                heading
                statusLine
            }
            .padding(.leading, 6)
            .background((isActive ? theme.highlightedWorktreeBackground : .clear), in: RoundedRectangle(cornerRadius: 6))
            .background(theme.background, in: RoundedRectangle(cornerRadius: 6))
        )
        SidebarWorktreeRowLayout {
            Button {
                if let singleRow { singleRow.onOpen() } else { onSelectRemoteWorktree(remoteMac, worktree.path) }
            } label: {
                identityView.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .rightClickMenu {
                remoteWorktreeMenu(worktree, context: context, remoteMac: remoteMac)
            }
        } content: {
            Button {
                if let singleRow { singleRow.onOpen() } else { onSelectRemoteWorktree(remoteMac, worktree.path) }
            } label: {
                heading
            }
            .buttonStyle(.plain)
            .id(worktree.path)
            .rightClickMenu {
                remoteWorktreeMenu(worktree, context: context, remoteMac: remoteMac)
            }
            .modifier(RemoteWorktreeDragSource(payload: .init(identity: identity, path: worktree.path), isEnabled: canReorder(worktree, on: remoteMac), preview: preview))
            .dropDestination(for: WorktreeRowDrop.self) { values, location in
                if let singleRow, let value = values.first, query.isEmpty, !worktree.state.isInFlight {
                    return singleRow.onDrop(value, location.y > 14)
                }
                guard query.isEmpty, !worktree.state.isInFlight,
                      editableProjectIDs.contains(SidebarProjection.projectID(worktree)),
                      case .remote(let value)? = values.first,
                      let source = value.resolve(on: identity, in: worktreePanesByRemote[identity] ?? []),
                      canReorder(source, on: remoteMac), source.path != worktree.path,
                      RemoteWorktreeReorderPolicy.areSiblings(source, worktree),
                      !worktree.isMainCheckout || location.y > 14 else { return false }
                moveRemoteWorktree(source, relativeTo: worktree, after: location.y > 14, remoteMac: remoteMac)
                return true
            }

            if status != .none || divergence != nil {
                Button {
                    if let singleRow {
                        if status.opensPane { singleRow.onOpenPane(context) } else { singleRow.onOpen() }
                    } else {
                        onSelectRemoteWorktree(remoteMac, worktree.path)
                    }
                } label: {
                    statusLine.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .rightClickMenu {
                    remoteWorktreeMenu(worktree, context: context, remoteMac: remoteMac)
                }
            }
        }
        .padding(.leading, 6)
        .opacity(isCached ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? theme.highlightedWorktreeBackground : .clear)
        )
        .padding(.vertical, SidebarWorktreeListStyle.macRowOuterInset)
    }

    /// A pinned agent on another host, as a tile with that host's badge.
    private func remoteTile(_ tile: SingleRow) -> some View {
        let worktree = tile.worktree
        let identity = RemoteMacIdentity(tile.remoteMac)
        let isActive = selectedRemoteIdentity == identity && selectedRemoteWorktreePath == worktree.path
        let context = contextForWorktree(worktree)
        let status = SidebarRowStatus.resolve(context: context, worktree: worktree, isCached: tile.isCached)
        let state = PinnedTileState.resolve(status: status, isCached: tile.isCached)
        let projectID = SidebarProjection.projectID(worktree)
        let project = projects.first { $0.id == projectID }
            ?? SidebarProject(id: projectID, repositoryID: worktree.repositoryID ?? projectID, name: worktree.repoDisplayName)
        let host = tile.hostLabel.flatMap { $0.isEmpty ? nil : $0 } ?? tile.remoteMac.label
        let face = PinnedTileFace(identity: worktree.iconIdentity, project: project,
                                  imageData: worktree.isMainCheckout ? projectIcons[projectID] : nil,
                                  word: PinnedTile.word(name: tile.displayName, isMainCheckout: worktree.isMainCheckout, branch: worktree.displayBranch),
                                  hostBadge: host, state: state, isSelected: isActive,
                                  fill: theme.foreground.opacity(0.07), selectedFill: theme.highlightedWorktreeBackground)
        return Button(action: tile.onOpen) { face }
            .buttonStyle(.plain)
            .rightClickMenu { remoteWorktreeMenu(worktree, context: context, remoteMac: tile.remoteMac) }
            .modifier(RemoteWorktreeDragSource(payload: .init(identity: identity, path: worktree.path),
                                               isEnabled: canReorder(worktree, on: tile.remoteMac), preview: AnyView(face.frame(width: 60))))
            .modifier(PinnedTileDropTarget(isEnabled: query.isEmpty && !worktree.state.isInFlight, onDrop: tile.onDrop))
            .modifier(PinnedTileHoverCard(name: tile.displayName, host: host, status: status, secondary: theme.sidebarSecondaryText))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PinnedTile.accessibilityLabel(name: tile.displayName, host: host, state: state))
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { tile.onOpen() }
            .id(worktree.path)
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
        var entry = WorktreeEntry(
            path: worktree.path,
            branch: worktree.displayBranch,
            state: WorktreeState(worktree.state)
        )
        entry.creationProgress = worktree.creationProgress
        entry.emoji = worktree.sidebar?.emoji
        return entry
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
        if singleRow?.isCached == true { return RemoteWorktreeReorderPolicy.allowsWhileAsleep(worktree, query: query) }
        return model.connectionState(for: RemoteMacIdentity(remoteMac)) == .connected
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
        context: SidebarWorktreeContext,
        remoteMac: RemoteMac
    ) -> NSMenu {
        let menu = NSMenu()
        SidebarAttentionDismissalMenu.add(to: menu, context: context) { context in
            onDismissRequest(context)
            dismissOnOwningMac(context, worktree: worktree, remoteMac: remoteMac)
        }
        guard !worktree.isMainCheckout, !worktree.state.isInFlight else {
            return menu.droppingTrailingSeparator()
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

    /// LAYOUT-2.218: the owning Mac retires the request, so every client stops showing it.
    private func dismissOnOwningMac(_ context: SidebarWorktreeContext, worktree: WorktreePanes, remoteMac: RemoteMac) {
        let requests = SidebarAttentionDismissal.requests(for: context,
            supportsExactAcknowledgement: editableProjectIDs.contains(SidebarProjection.projectID(worktree)))
        guard !requests.isEmpty else { return }
        Task { @MainActor in
            let alert = NSAlert()
            do {
                guard let message = try await SidebarAttentionDismissal.retire(requests, send: {
                    try await model.retireRequest($0, on: remoteMac)
                }) else { return }
                alert.messageText = "Couldn't dismiss this request on \(remoteMac.label)"
                alert.informativeText = message
            } catch {
                alert.messageText = "Couldn't reach the owning Mac"
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
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
