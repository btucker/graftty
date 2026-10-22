#if canImport(UIKit)
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI

struct RemoteMacConnectionRow: View {
    let remoteMac: RemoteMacConnectionSummary
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
            if isReconnecting || remoteMac.state == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting to \(remoteMac.label)")
            } else if remoteMac.state.mobileCanReconnect {
                Button(remoteMac.state.mobileReconnectLabel) {
                    onReconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(
                    "\(remoteMac.state.mobileReconnectLabel) to \(remoteMac.label)"
                )
            }
        }
    }

    private var subtitle: String {
        [remoteMac.lastKnownHost, remoteMac.state.mobileStatusText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

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
