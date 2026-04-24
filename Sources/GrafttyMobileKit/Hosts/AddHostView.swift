#if canImport(UIKit)
import SwiftUI

public struct AddHostView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AddMode = .direct
    @State private var rawURL: String = ""
    @State private var label: String = ""
    @State private var scanError: String?
    @State private var isScanning = true
    @State private var sshHost: String = ""
    @State private var sshPort: Int = 22
    @State private var sshUsername: String = ""
    @State private var remoteGrafttyPort: Int = 8799
    @State private var publicKey: String?
    @State private var publicKeyFileURL: URL?
    @State private var sshError: String?

    private enum AddMode: String, CaseIterable, Identifiable {
        case direct
        case ssh

        var id: String { rawValue }
        var title: String {
            switch self {
            case .direct: "URL"
            case .ssh: "SSH"
            }
        }
    }

    public let onSave: (Host) throws -> Void

    public init(onSave: @escaping (Host) throws -> Void) {
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            if mode == .direct && isScanning {
                scanner
                    .toolbar { toolbarItems(showManualEntry: true) }
            } else if mode == .direct {
                manualForm
                    .toolbar { toolbarItems(showManualEntry: false) }
            } else {
                sshForm
                    .toolbar { toolbarItems(showManualEntry: false) }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarItems(showManualEntry: Bool) -> some ToolbarContent {
        if showManualEntry {
            ToolbarItem(placement: .confirmationAction) {
                Button("Manual entry") { isScanning = false }
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
    }

    private var scanner: some View {
        QRScannerView { value in
            handle(rawURL: value)
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if let scanError {
                Text(scanError).padding().background(.thinMaterial).cornerRadius(8).padding()
            }
        }
    }

    private var manualForm: some View {
        Form {
            modePicker
            Section("Graftty server") {
                TextField("Label (e.g. 'laptop')", text: $label)
                TextField("URL", text: $rawURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if let scanError {
                Section { Text(scanError).foregroundStyle(.red) }
            }
            Button("Save") {
                handle(rawURL: rawURL)
            }
            .disabled(rawURL.isEmpty || label.isEmpty)
        }
    }

    private var sshForm: some View {
        Form {
            modePicker
            Section("Generated public key") {
                if let publicKey {
                    Text(publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if let publicKeyFileURL {
                        ShareLink("Share public key", item: publicKeyFileURL)
                    }
                } else {
                    ProgressView()
                }
                Text(SSHOnboardingInstructions.downloadedFile())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("SSH host") {
                TextField("Label (e.g. 'laptop')", text: $label)
                TextField("Host", text: $sshHost)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $sshUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("SSH port", value: $sshPort, format: .number)
                    .keyboardType(.numberPad)
                TextField("Graftty port", value: $remoteGrafttyPort, format: .number)
                    .keyboardType(.numberPad)
            }
            if let sshError {
                Section { Text(sshError).foregroundStyle(.red) }
            }
            Button("Save") {
                handleSSH()
            }
            .disabled(!canSaveSSH)
        }
        .task { loadPublicKey() }
    }

    private var modePicker: some View {
        Picker("Connection", selection: $mode) {
            ForEach(AddMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var canSaveSSH: Bool {
        !label.isEmpty
            && !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sshUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(sshPort)
            && (1...65535).contains(remoteGrafttyPort)
    }

    private func handle(rawURL: String) {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let urlHost = url.host, !urlHost.isEmpty else {
            scanError = "QR did not contain a Graftty URL"
            return
        }
        let host = Host(
            label: label.isEmpty ? urlHost : label,
            baseURL: url
        )
        do {
            try onSave(host)
            dismiss()
        } catch {
            scanError = "Couldn't save: \(error)"
        }
    }

    private func loadPublicKey() {
        guard publicKey == nil else { return }
        do {
            let key = try MobileSSHKeyStore().publicKey()
            publicKey = key
            publicKeyFileURL = try writePublicKeyExportFile(key)
            sshError = nil
        } catch {
            sshError = "Could not generate SSH key: \(error)"
        }
    }

    private func writePublicKeyExportFile(_ key: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrafttyMobileSSH", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("graftty-mobile.pub")
        try key.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func handleSSH() {
        guard canSaveSSH else { return }
        let host = Host(
            label: label,
            transport: .sshTunnel(SSHHostConfig(
                sshHost: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
                sshPort: sshPort,
                sshUsername: sshUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                remoteGrafttyHost: "127.0.0.1",
                remoteGrafttyPort: remoteGrafttyPort
            ))
        )
        do {
            try onSave(host)
            dismiss()
        } catch {
            sshError = "Couldn't save: \(error)"
        }
    }
}
#endif
