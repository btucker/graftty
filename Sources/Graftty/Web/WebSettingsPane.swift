import SwiftUI
import GrafttyKit
import GrafttyHostAgent

struct WebSettingsPane: View {
    @StateObject private var settings = WebAccessSettings.shared
    @EnvironmentObject private var controller: WebServerController
    @ObservedObject var pairingCoordinator: RemoteMacHostPairingCoordinator
    let trustedPeerStore: TrustedPeerStore
    let sshConnectionRegistry: SSHConnectionRegistry

    private static let tailscaleAdminDNSURL = URL(string: "https://login.tailscale.com/admin/dns")!

    var body: some View {
        Form {
            Section {
                Toggle("Enable web access", isOn: $settings.isEnabled)
                TextField("Port", value: $settings.port, format: WebPortFormat.noGrouping)
                    .frame(width: 80)
                statusRow
                if case let .listening(_, port) = controller.status,
                   let host = controller.serverHostname {
                    baseURLRow(url: WebURLComposer.baseURL(host: host, port: port))
                }
            } header: {
                Text("Web Access")
            } footer: {
                Text("Serves HTTPS only. Binds to Tailscale IPs. Allows only your Tailscale identity.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            PairedDevicesSection(
                pairingCoordinator: pairingCoordinator,
                trustedPeerStore: trustedPeerStore,
                sshConnectionRegistry: sshConnectionRegistry
            )
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 440)
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
                adminConsoleError("MagicDNS must be enabled on your tailnet.")
            case .httpsCertsNotEnabled:
                adminConsoleError("HTTPS certificates must be enabled on your tailnet.")
            case .provisioningCert:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Provisioning certificate from Tailscale…")
                        .foregroundStyle(.secondary)
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

    @ViewBuilder private func adminConsoleError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message).foregroundStyle(.orange)
            Link("Open Tailscale admin", destination: Self.tailscaleAdminDNSURL)
                .font(.caption)
        }
    }
}
