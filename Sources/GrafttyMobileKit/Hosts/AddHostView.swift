#if canImport(UIKit)
import SwiftUI

public struct AddHostView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rawURL: String = ""
    @State private var label: String = ""
    @State private var scanError: String?
    @State private var isScanning = true

    public let onSave: (Host) throws -> Void

    public init(onSave: @escaping (Host) throws -> Void) {
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isScanning {
                    scanner
                } else {
                    manualForm
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Manual entry") { isScanning = false }
                        .opacity(isScanning ? 1 : 0)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
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
}
#endif
