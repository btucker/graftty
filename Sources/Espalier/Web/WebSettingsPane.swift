import SwiftUI
import EspalierKit

struct WebSettingsPane: View {
    @StateObject private var settings = WebAccessSettings.shared
    @EnvironmentObject private var controller: WebServerController

    var body: some View {
        Form {
            Section {
                Toggle("Enable web access", isOn: $settings.isEnabled)
                TextField("Port", value: $settings.port, format: .number)
                    .frame(width: 80)
                statusRow
                if case .listening = controller.status, let url = controller.currentURL {
                    Text("Base URL: \(url)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Web Access")
            } footer: {
                Text("Binds only to Tailscale IPs. Allows only your Tailscale identity.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 240)
    }

    @ViewBuilder private var statusRow: some View {
        HStack {
            Text("Status:")
            switch controller.status {
            case .stopped:
                Text("Stopped").foregroundStyle(.secondary)
            case .listening(let addrs, let port):
                Text("Listening on \(addrs.joined(separator: ", ")):\(port)")
                    .foregroundStyle(.green)
            case .disabledNoTailscale:
                Text("Tailscale unavailable").foregroundStyle(.orange)
            case .portUnavailable:
                Text("Port in use").foregroundStyle(.red)
            case .error(let msg):
                Text("Error: \(msg)").foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
