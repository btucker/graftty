import SwiftUI
import GrafttyKit

struct RemoteMacConnectionsPopover: View {
    @ObservedObject var model: RemoteMacsModel
    let onAddRemoteMac: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remote Macs").font(.headline).padding(12)
            Divider()
            if model.savedRemoteMacs.isEmpty {
                Text("No remote Macs added yet.")
                    .foregroundStyle(.secondary).padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.savedRemoteMacs) { mac in
                            machineRow(mac)
                        }
                    }.padding(.vertical, 4)
                }.frame(height: min(CGFloat(model.savedRemoteMacs.count) * 64 + 8, 328))
            }
            Divider()
            Button(action: onAddRemoteMac) {
                Label("Add Remote Mac…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(12)
        }.frame(width: 340)
    }

    private func machineRow(_ mac: RemoteMac) -> some View {
        let state = model.connectionState(for: RemoteMacIdentity(mac))
        return HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.label).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(state.statusColor).frame(width: 6, height: 6)
                    Text(state.statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if state == .connecting {
                ProgressView().controlSize(.small)
            } else if let title = state.connectionActionTitle {
                Button(title) {
                    if state == .needsPairing { onAddRemoteMac() }
                    else {
                        Task { _ = await model.reconnectRemoteMac(deviceID: mac.id, fingerprint: mac.fingerprint) }
                    }
                }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).frame(height: 64)
        .help(mac.lastKnownBaseURL?.host ?? mac.label)
    }
}

extension RemoteMacConnectionState {
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
