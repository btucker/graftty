import SwiftUI
import GrafttyKit

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
                Text("Serves HTTPS only. Binds to Tailscale IPs. Allows only your Tailscale identity.")
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
        HStack(alignment: .firstTextBaseline) {
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
            case .tailscaleUnavailable:
                Text("Tailscale unavailable").foregroundStyle(.orange)
            case .magicDNSDisabled:
                VStack(alignment: .leading, spacing: 2) {
                    Text("MagicDNS must be enabled on your tailnet.")
                        .foregroundStyle(.orange)
                    Link(
                        "Open Tailscale admin",
                        destination: URL(string: "https://login.tailscale.com/admin/dns")!
                    )
                    .font(.caption)
                }
            case .httpsCertsNotEnabled:
                VStack(alignment: .leading, spacing: 2) {
                    Text("HTTPS certificates must be enabled on your tailnet.")
                        .foregroundStyle(.orange)
                    Link(
                        "Open Tailscale admin",
                        destination: URL(string: "https://login.tailscale.com/admin/dns")!
                    )
                    .font(.caption)
                }
            case .certFetchFailed(let msg):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Could not fetch certificate: \(msg)")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Text("Graftty will retry automatically.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            case .portUnavailable:
                Text("Port in use").foregroundStyle(.red)
            case .error(let msg):
                Text("Error: \(msg)").foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
