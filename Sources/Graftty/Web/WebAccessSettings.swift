import SwiftUI

enum WebAccessMode: String, CaseIterable, Identifiable {
    case tailscale
    case sshTunnel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tailscale: "Tailscale"
        case .sshTunnel: "SSH Tunnel"
        }
    }
}

/// Minimal @AppStorage-backed settings model. Off by default; port
/// defaults to 8799.
@MainActor
final class WebAccessSettings: ObservableObject {
    @AppStorage("WebAccessEnabled") var isEnabled: Bool = false
    @AppStorage("WebAccessPort") var port: Int = 8799
    @AppStorage("WebAccessMode") private var modeRawValue: String = WebAccessMode.tailscale.rawValue

    var mode: WebAccessMode {
        get { WebAccessMode(rawValue: modeRawValue) ?? .tailscale }
        set { modeRawValue = newValue.rawValue }
    }

    static let shared = WebAccessSettings()
}
