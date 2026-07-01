#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

public struct AddHostView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rawURL: String = ""
    @State private var label: String = ""
    @State private var scanError: String?
    @State private var isScanning = true
    @State private var pairingPayload: PairingPayload?

    public let onSave: (Host) throws -> Void

    public init(onSave: @escaping (Host) throws -> Void) {
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            if let pairingPayload {
                PairDeviceFlowView(
                    payload: pairingPayload,
                    onSave: onSave,
                    onRetry: { self.pairingPayload = nil }
                )
            } else if isScanning {
                scanner
                    .toolbar { toolbarItems(showManualEntry: true) }
            } else {
                manualForm
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

    // MARK: - Routing (unit-testable, no SwiftUI/View state)

    /// What `handle(rawURL:)` should do with a scanned/typed string.
    enum Route: Equatable {
        /// A valid pairing QR payload — switch to the pairing ceremony.
        case pairing(PairingPayload)
        /// A plain `http(s)://` URL with a host — the existing manual/URL path.
        case url(URL)
        /// Neither a pairing payload nor a usable URL.
        case invalid
    }

    /// Pure classification of a scanned/typed string, tried in this order:
    /// 1. `PairingPayload.decodeQR` — any `DecodeError` falls through.
    /// 2. The pre-existing http(s)+host URL check.
    static func route(for rawURL: String) -> Route {
        if let payload = try? PairingPayload.decodeQR(rawURL) {
            return .pairing(payload)
        }
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let urlHost = url.host, !urlHost.isEmpty else {
            return .invalid
        }
        return .url(url)
    }

    private func handle(rawURL: String) {
        switch Self.route(for: rawURL) {
        case .pairing(let payload):
            pairingPayload = payload
        case .url(let url):
            let host = Host(
                label: label.isEmpty ? (url.host ?? "") : label,
                baseURL: url
            )
            do {
                try onSave(host)
                dismiss()
            } catch {
                scanError = "Couldn't save: \(error)"
            }
        case .invalid:
            scanError = "QR did not contain a Graftty URL"
        }
    }
}
#endif
