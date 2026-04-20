import SwiftUI
import EspalierKit

struct WebSettingsPane: View {
    @StateObject private var settings = WebAccessSettings.shared
    @EnvironmentObject private var controller: WebServerController

    var body: some View {
        Form {
            Section {
                Toggle("Enable web access", isOn: $settings.isEnabled)
                TextField("Port", value: $settings.port, format: WebPortFormat.noGrouping)
                    .frame(width: 80)
                statusRow
                if case .listening = controller.status, let url = controller.currentURL {
                    baseURLRow(url: url)
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

    /// "Base URL: <link>  [copy]" — a clickable `Link` that opens in the
    /// default browser plus an `NSPasteboard` copy button. Falls back to
    /// plain selectable text if the string somehow isn't a parseable URL
    /// (shouldn't happen: WebURLComposer always emits a well-formed URL).
    /// WEB-1.12.
    @ViewBuilder private func baseURLRow(url: String) -> some View {
        HStack(spacing: 8) {
            Text("Base URL:")
            Group {
                if let parsed = URL(string: url) {
                    Link(url, destination: parsed)
                } else {
                    Text(url)
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            Button { Pasteboard.copy(url) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy URL")
            .accessibilityLabel("Copy URL")
        }
    }

    @ViewBuilder private var statusRow: some View {
        HStack {
            Text("Status:")
            switch controller.status {
            case .stopped:
                Text("Stopped").foregroundStyle(.secondary)
            case .listening(let addrs, let port):
                // `verbatim:` because `Text("…\(port)")` goes through
                // LocalizedStringKey, which formats `Int` with the
                // locale's grouping separator (e.g., `12,345`). Format
                // each address with its port via `authority(...)` so
                // IPv6 gets bracketed and the port isn't ambiguously
                // floating off the last address (WEB-1.10).
                let joined = addrs
                    .map { WebURLComposer.authority(host: $0, port: port) }
                    .joined(separator: ", ")
                Text(verbatim: "Listening on \(joined)")
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
