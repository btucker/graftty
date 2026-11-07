import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

struct RemoteMacConnectionsPopover: View {
    private typealias Connections = DownstreamHostConnections<RemoteMacIdentity>
    @ObservedObject var model: RemoteMacsModel
    private var downstream: Connections { model.downstreamConnections }
    let onAddRemoteMac: () -> Void
    var onSetupLinuxHost: (() -> Void)? = nil
    var onUpdateHost: ((RemoteMac) -> Void)? = nil

    private var hosts: [Connections.Host] {
        model.savedRemoteMacs.map { mac in
            let identity = RemoteMacIdentity(mac)
            return .init(id: identity, label: mac.label, isConnected: model.connectionState(for: identity) == .connected)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remote Hosts").font(.headline).padding(12)
            Divider()
            if model.savedRemoteMacs.isEmpty {
                Text("No remote hosts added yet.")
                    .foregroundStyle(.secondary).padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.savedRemoteMacs) { mac in
                            machineRow(mac)
                        }
                        if !downstream.routes.isEmpty {
                            Divider()
                            Text("Through another Mac")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            ForEach(downstream.routes) { route in
                                downstreamRow(route)
                            }
                        }
                    }.padding(.vertical, 4)
                }.frame(height: min(CGFloat(model.savedRemoteMacs.count + downstream.routes.count) * 64 + (downstream.routes.isEmpty ? 8 : 48), 420))
            }
            Divider()
            Button(action: onAddRemoteMac) {
                Label("Add Remote Mac…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(12)
            if let onSetupLinuxHost {
                Button(action: onSetupLinuxHost) {
                    Label("Set Up Linux Host…", systemImage: "server.rack")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(12)
            }
        }.frame(width: 340)
        .alert("Couldn't connect host", isPresented: Binding(
            get: { downstream.error != nil },
            set: { if !$0 { downstream.error = nil } }
        )) {
            Button("OK", role: .cancel) { downstream.error = nil }
        } message: { Text(downstream.error ?? "") }
        .task(id: hosts) {
            while !Task.isCancelled {
                await downstream.refresh(hosts: hosts, send: send)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func send(_ identity: RemoteMacIdentity, _ request: WorktreeManagementRequest) async throws -> WorktreeManagementResponse {
        guard let mac = model.savedRemoteMacs.first(where: { RemoteMacIdentity($0) == identity }) else {
            throw RemoteMacsModel.ProjectControlError.unavailable
        }
        if case .connectRemoteMac = request {
            _ = try await model.connectFromUserSelection(to: mac)
        } else if model.connectionState(for: identity) != .connected {
            throw RemoteMacsModel.ProjectControlError.unavailable
        }
        return try await model.sendWorktreeManagement(identity: identity, request: request)
    }

    private func downstreamRow(_ route: Connections.Route) -> some View {
        let state = route.target.state
        return HStack(spacing: 10) {
            Image(systemName: "network").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(route.target.label).lineLimit(1)
                Text("via \(route.host.label) · \(route.host.isConnected ? RemoteMacConnectionState(state).statusText : "Mac not connected")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if downstream.connecting.contains(route.id) || (route.host.isConnected && state == .connecting) {
                ProgressView().controlSize(.small)
            } else if state == .needsPairing {
                Text("Pair on \(route.host.label)").font(.caption).foregroundStyle(.secondary)
            } else if !route.host.isConnected || state != .connected {
                Button(state == .failed ? "Retry" : "Connect") {
                    Task {
                        await downstream.connect(route, send: send)
                        await downstream.refresh(hosts: hosts, send: send)
                    }
                }
                .controlSize(.small)
                .accessibilityLabel("Connect to \(route.label)")
            }
        }
        .padding(.horizontal, 12).frame(height: 64)
    }

    private func machineRow(_ mac: RemoteMac) -> some View {
        let identity = RemoteMacIdentity(mac)
        let state = model.connectionState(for: identity)
        let feedFailure = model.paneFeedFailure(for: identity)
        return HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.label).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(feedFailure == nil ? state.statusColor : .orange).frame(width: 6, height: 6)
                    Text(feedFailure == nil ? state.statusText : "Worktree feed unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let onUpdateHost, model.maintenanceHost(for: mac) != nil {
                Button("Update Host…") { onUpdateHost(mac) }
                    .controlSize(.small)
                    .accessibilityIdentifier("updateHost-\(mac.id.value)")
            }
            if state == .connecting {
                ProgressView().controlSize(.small)
            } else if let title = state.connectionActionTitle {
                Button(title) {
                    if state == .needsPairing { onAddRemoteMac() }
                    else {
                        Task {
                            do { try await model.connectHostUsingAvailableRoutes(mac) }
                            catch { downstream.error = error.localizedDescription }
                        }
                    }
                }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).frame(height: 64)
        .help(feedFailure ?? mac.lastKnownBaseURL?.host ?? mac.label)
    }
}

extension RemoteMacConnectionState {
    init(_ state: RemoteMacConnectionSummary.State) {
        switch state {
        case .offline: self = .offline
        case .discovered: self = .discovered
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .failed: self = .failed
        case .needsPairing: self = .needsPairing
        }
    }

    var statusText: String {
        switch self {
        case .offline: "Offline"
        case .discovered: "Available"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Connection failed"
        case .needsPairing: "Pairing required"
        }
    }

    var connectionActionTitle: String? {
        switch self {
        case .offline, .discovered: "Connect"
        case .failed: "Retry"
        case .needsPairing: "Pair…"
        case .connecting, .connected: nil
        }
    }

    fileprivate var statusColor: Color {
        switch self {
        case .connected: .green
        case .connecting, .discovered: .accentColor
        case .failed, .needsPairing: .orange
        case .offline: .secondary
        }
    }
}
