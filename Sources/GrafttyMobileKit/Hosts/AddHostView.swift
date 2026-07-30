#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// Device-first Mac onboarding. Nearby and manually entered addresses are
/// only pairing bootstraps: no `Host` is created until the verification-code
/// ceremony succeeds and `ClientPairingSession` pins the Mac's identity.
public struct AddHostView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manualAddress = ""
    @State private var errorMessage: String?
    @State private var isStartingPairing = false
    @State private var pairingPayload: PairingPayload?
    @State private var pairingBootstrapTask: Task<Void, Never>?
    @State private var pairingBootstrapID: UUID?

    @Bindable private var browser: NearbyMacBrowser
    public let onSave: (Host) throws -> Void

    public init(
        browser: NearbyMacBrowser = NearbyMacBrowser(),
        onSave: @escaping (Host) throws -> Void
    ) {
        self.browser = browser
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            if let pairingPayload {
                PairDeviceFlowView(
                    payload: pairingPayload,
                    onSave: onSave,
                    onRetry: {
                        errorMessage = nil
                        self.pairingPayload = nil
                    }
                )
            } else {
                pairingPicker
            }
        }
        .task { browser.start() }
        .onDisappear {
            cancelPairingBootstrap()
        }
    }

    private var pairingPicker: some View {
        List {
            Section {
                if browser.candidates.isEmpty {
                    HStack(spacing: 12) {
                        if browser.isSearching {
                            ProgressView()
                        } else {
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                        }
                        Text("Open Graftty on a Mac connected to this local network.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(browser.candidates) { candidate in
                        Button {
                            beginPairing(
                                at: candidate.baseURL,
                                expectedCandidate: candidate
                            )
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.label)
                                    Text(candidate.baseURL.host ?? candidate.baseURL.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(
                            isStartingPairing
                                || candidate.pairingStatus == .pairedOnly
                        )
                    }
                }
            } header: {
                Text("Nearby Macs")
            } footer: {
                if let discoveryError = browser.errorMessage {
                    Text(discoveryError)
                } else {
                    Text("Your Mac will ask you to compare and confirm a verification code.")
                }
            }

            Section("Pair by LAN address") {
                TextField("http://mac.local:port", text: $manualAddress)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(isStartingPairing)
                Button("Pair") {
                    guard let baseURL = Self.manualPairingBaseURL(
                        manualAddress
                    ) else {
                        errorMessage = "Enter a valid HTTP or HTTPS address."
                        return
                    }
                    beginPairing(at: baseURL)
                }
                .disabled(
                    isStartingPairing
                        || Self.manualPairingBaseURL(manualAddress) == nil
                )
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Pair a Mac")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    cancelPairingBootstrap()
                    dismiss()
                }
            }
        }
        .overlay {
            if isStartingPairing {
                ProgressView("Starting pairing…")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// Validates a manual address as a pairing bootstrap. This deliberately
    /// returns only the URL—not a `Host`—so no caller can accidentally
    /// resurrect the old "save a bare server URL" path.
    static func manualPairingBaseURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }
        return url
    }

    private func beginPairing(
        at baseURL: URL,
        expectedCandidate: NearbyMac? = nil
    ) {
        guard !isStartingPairing else { return }
        isStartingPairing = true
        errorMessage = nil
        let attemptID = UUID()
        pairingBootstrapID = attemptID
        let task = Task { @MainActor in
            defer {
                if pairingBootstrapID == attemptID {
                    pairingBootstrapID = nil
                    pairingBootstrapTask = nil
                    isStartingPairing = false
                }
            }
            do {
                let payload = try await PairDeviceFlowView.beginPairing(
                    baseURL: baseURL
                )
                guard !Task.isCancelled,
                      pairingBootstrapID == attemptID else {
                    return
                }
                if let expectedCandidate,
                   (
                       payload.hostDeviceID != expectedCandidate.deviceID
                           || payload.hostPublicKeyFingerprint
                               != expectedCandidate.fingerprint
                   ) {
                    errorMessage =
                        "The Mac's pairing identity changed during discovery. "
                        + "Refresh and verify the device before trying again."
                    return
                }
                pairingPayload = payload
            } catch LocalPairingClient.Error.cancelled {
                // Dismissal is not a pairing failure to surface.
            } catch {
                if !Task.isCancelled, pairingBootstrapID == attemptID {
                    errorMessage = Self.message(for: error)
                }
            }
        }
        pairingBootstrapTask = task
    }

    private func cancelPairingBootstrap() {
        pairingBootstrapID = nil
        pairingBootstrapTask?.cancel()
        pairingBootstrapTask = nil
        isStartingPairing = false
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let LocalPairingClient.Error.serverError(response):
            return response.error
        case LocalPairingClient.Error.httpStatus(409):
            return "That Mac is already pairing with another device."
        case let LocalPairingClient.Error.httpStatus(status):
            return "The Mac returned HTTP \(status)."
        default:
            return "Couldn't start pairing: \(error.localizedDescription)"
        }
    }
}
#endif
