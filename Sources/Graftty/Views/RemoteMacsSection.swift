import SwiftUI
import GrafttyKit

struct RemoteMacsSidebarProjection: Equatable {
    enum Action: Equatable {
        case addRemoteMac
    }

    struct Row: Identifiable, Equatable {
        let id: RemoteMacIdentity
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
        selectedRemoteIdentity: RemoteMacIdentity?,
        connectionState: (RemoteMacIdentity) -> RemoteMacConnectionState
    ) -> RemoteMacsSidebarProjection {
        let rows = savedRemoteMacs.map { remoteMac in
            let identity = RemoteMacIdentity(remoteMac)
            return Row(
                id: identity,
                title: remoteMac.label,
                subtitle: remoteMac.lastKnownBaseURL?.host,
                connectionState: connectionState(identity),
                isSelected: selectedRemoteIdentity == identity
            )
        }
        return RemoteMacsSidebarProjection(
            title: "Remote Macs",
            rows: rows,
            addAction: .addRemoteMac
        )
    }
}

struct RemoteMacSidebarSelectionState: Equatable {
    var selectedWorktreePath: String?
    var selectedRemoteIdentity: RemoteMacIdentity?
}

enum RemoteMacSidebarSelectionReducer {
    static func selectRemote(
        _ identity: RemoteMacIdentity,
        state: inout RemoteMacSidebarSelectionState
    ) {
        state.selectedWorktreePath = nil
        state.selectedRemoteIdentity = identity
    }

    static func selectLocalWorktree(
        _ path: String,
        state: inout RemoteMacSidebarSelectionState
    ) {
        state.selectedWorktreePath = path
        state.selectedRemoteIdentity = nil
    }
}

struct RemoteMacsSection: View {
    @ObservedObject var model: RemoteMacsModel
    let selectedRemoteIdentity: RemoteMacIdentity?
    let theme: GhosttyTheme
    let onSelectRemoteMac: (RemoteMac) -> Void
    let onAddRemoteMac: () -> Void

    private var projection: RemoteMacsSidebarProjection {
        RemoteMacsSidebarProjection.make(
            savedRemoteMacs: model.savedRemoteMacs,
            discoveryCandidates: model.discoveryCandidates,
            selectedRemoteIdentity: selectedRemoteIdentity,
            connectionState: { model.connectionState(for: $0) }
        )
    }

    var body: some View {
        Section {
            ForEach(projection.rows) { row in
                if let remoteMac = model.savedRemoteMacs.first(where: { RemoteMacIdentity($0) == row.id }) {
                    Button {
                        onSelectRemoteMac(remoteMac)
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

    private func remoteRow(_ row: RemoteMacsSidebarProjection.Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: row.connectionState))
                .foregroundStyle(iconColor(for: row.connectionState))
                .frame(width: 16)
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
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(row.isSelected ? theme.foreground.opacity(0.16) : .clear)
        )
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
