import SwiftUI
import GrafttyKit

struct WebSettingsPane: View {
    @StateObject private var settings = WebAccessSettings.shared
    @EnvironmentObject private var controller: WebServerController

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
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 440)
    }

    /// "Base URL: <link>  [copy]" — a clickable `Link` that opens in the
    /// default browser plus an `NSPasteboard` copy button. Falls back to
    /// plain selectable text if the string somehow isn't a parseable URL
    /// (shouldn't happen: WebURLComposer always emits a well-formed URL).
    /// Also shows an inline QR code for iOS onboarding (WEB-1.13). WEB-1.12.
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
        HStack(alignment: .top, spacing: 12) {
            QRCodeView(text: url, size: 160)
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan with Graftty").font(.caption).foregroundStyle(.secondary)
                Text("On your iPhone or iPad on this tailnet, open Graftty → + → scan this QR to add this Mac as a saved host.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
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
