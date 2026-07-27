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
    let onAddRemoteMac: () -> Void

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
            ForEach(projection.rows) { row in
                if let remoteMac = model.savedRemoteMacs.first(where: { RemoteMacIdentity($0) == row.remoteIdentity }) {
                    Button {
                        select(row, remoteMac: remoteMac)
                    } label: {
                        remoteRow(row)
                    }
                    .buttonStyle(.plain)
                }
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

    private func select(_ row: RemoteMacsSidebarProjection.Row, remoteMac: RemoteMac) {
        switch row.level {
        case .remoteMac:
            onSelectRemoteMac(remoteMac)
        case .worktree:
            if let worktreePath = row.worktreePath {
                onSelectRemoteWorktree(remoteMac, worktreePath)
            }
        case .pane:
            if let worktreePath = row.worktreePath, let sessionName = row.sessionName {
                onSelectRemotePane(remoteMac, worktreePath, sessionName)
            }
        }
    }

    private func remoteRow(_ row: RemoteMacsSidebarProjection.Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: row.connectionState))
                .foregroundStyle(iconColor(for: row.connectionState))
                .frame(width: 16)
                .opacity(row.level == .pane ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .lineLimit(1)
                    .foregroundColor(theme.sidebarPrimaryText(isActive: row.isSelected))
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, leadingPadding(for: row.level))
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(row.isSelected ? theme.foreground.opacity(0.16) : .clear)
        )
    }

    private func leadingPadding(for level: RemoteMacsSidebarProjection.RowLevel) -> CGFloat {
        switch level {
        case .remoteMac:
            4
        case .worktree:
            16
        case .pane:
            28
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
