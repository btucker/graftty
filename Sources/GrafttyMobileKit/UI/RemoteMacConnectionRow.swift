#if canImport(UIKit)
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI

struct RemoteMacConnectionRow: View {
    let remoteMac: RemoteMacConnectionSummary
    var viaHostLabel: String? = nil
    var isIntermediaryConnected = true
    let isReconnecting: Bool
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: remoteMac.state.mobileSystemImage)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(remoteMac.label)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isReconnecting || (isIntermediaryConnected && remoteMac.state == .connecting) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting to \(remoteMac.label)")
            } else if remoteMac.state != .needsPairing && (!isIntermediaryConnected || remoteMac.state.mobileCanReconnect) {
                Button(reconnectLabel) {
                    onReconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(
                    "\(reconnectLabel) to \(remoteMac.label)\(viaHostLabel.map { " via \($0)" } ?? "")"
                )
            }
        }
    }

    private var subtitle: String {
        [viaHostLabel.map { "via \($0)" } ?? remoteMac.lastKnownHost,
         isIntermediaryConnected ? remoteMac.state.mobileStatusText : "Mac not connected"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var reconnectLabel: String { isIntermediaryConnected ? remoteMac.state.mobileReconnectLabel : "Connect" }

    private var iconColor: Color {
        switch remoteMac.state {
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

extension RemoteMacConnectionSummary.State {
    var mobileSystemImage: String {
        switch self {
        case .offline: "laptopcomputer"
        case .discovered: "wifi"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .needsPairing: "key"
        }
    }

    var mobileStatusText: String {
        switch self {
        case .offline: "Offline"
        case .discovered: "Available"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .failed: "Connection failed"
        case .needsPairing: "Pair again on the connected Mac"
        }
    }

    var mobileCanReconnect: Bool {
        self != .connecting && self != .needsPairing
    }

    var mobileReconnectLabel: String {
        self == .discovered ? "Connect" : "Reconnect"
    }
}
#endif
