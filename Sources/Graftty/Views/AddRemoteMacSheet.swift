import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

protocol AddRemoteMacPairingDriving: AnyObject {
    func beginPairing(baseURL: URL) async throws -> RemoteVerificationCode
    func confirmPairing() async throws -> PinnedHost
    func cancelPairing()
}

final class LocalAddRemoteMacPairingDriver: AddRemoteMacPairingDriving {
    private let session: ClientPairingSession
    private let client: LocalPairingClient

    init(
        identityStore: ClientIdentityStore,
        pinnedHostStore: PinnedHostStore,
        clientDeviceID: RemoteDeviceID,
        clientKind: RemoteDeviceKind,
        clientDisplayName: String,
        transport: @escaping LocalPairingClient.Transport = LocalPairingClient.defaultTransport
    ) {
        let session = ClientPairingSession(
            identityStore: identityStore,
            pinnedHostStore: pinnedHostStore,
            clientDeviceID: clientDeviceID,
            clientKind: clientKind,
            clientDisplayName: clientDisplayName
        )
        self.session = session
        self.client = LocalPairingClient(
            session: session,
            identityStore: identityStore,
            transport: transport
        )
    }

    func beginPairing(baseURL: URL) async throws -> RemoteVerificationCode {
        let payload = try await client.beginPairing(baseURL: baseURL)
        try Task.checkCancellation()
        return try await client.introduce(payload: payload)
    }

    func confirmPairing() async throws -> PinnedHost {
        try await client.awaitOutcomeAndConfirm()
    }

    func cancelPairing() {
        session.cancel()
    }
}

struct AddRemoteMacSheetLifecycle {
    var startDiscovery: () -> Void
    var stopDiscovery: () -> Void

    func appear() {
        startDiscovery()
    }

    func disappear() {
        stopDiscovery()
    }
}

struct AddRemoteMacFormController: Equatable {
    enum Phase: Equatable {
        case idle
        case candidateSelected(RemoteMacIdentity)
        case manualURLReady(URL)
        case verifying(RemoteVerificationCode)
        case failed(String)
    }

    enum ManualURLError: Error, Equatable {
        case empty
        case invalid
        case unsupportedScheme
        case missingHost
        case loopback

        var message: String {
            switch self {
            case .empty:
                "Enter a URL."
            case .invalid:
                "Enter a valid URL."
            case .unsupportedScheme:
                "Use http or https."
            case .missingHost:
                "Enter a URL with a host."
            case .loopback:
                "Use the remote Mac's LAN address, not localhost."
            }
        }
    }

    var manualURLString: String = ""
    var selectedCandidateIdentity: RemoteMacIdentity?
    var selectedPairingBaseURL: URL?
    var phase: Phase = .idle

    var canConfirmVerification: Bool {
        if case .verifying = phase { return true }
        return false
    }

    mutating func selectCandidate(_ candidate: GrafttyBonjourCandidate) {
        let identity = RemoteMacIdentity(candidate)
        selectedCandidateIdentity = identity
        selectedPairingBaseURL = candidate.baseURL
        phase = .candidateSelected(identity)
    }

    mutating func updateManualURL(_ value: String) {
        manualURLString = value
        switch Self.validateManualURL(value) {
        case .success(let url):
            selectedCandidateIdentity = nil
            selectedPairingBaseURL = url
            phase = .manualURLReady(url)
        case .failure:
            if selectedCandidateIdentity == nil {
                selectedPairingBaseURL = nil
                phase = .idle
            }
        }
    }

    mutating func showVerificationCode(_ code: RemoteVerificationCode) {
        phase = .verifying(code)
    }

    static func validateManualURL(_ value: String) -> Result<URL, ManualURLError> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased()
        else {
            return .failure(.invalid)
        }
        guard scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme)
        }
        guard let host = components.host, !host.isEmpty else {
            return .failure(.missingHost)
        }
        guard !isLoopbackHost(host) else {
            return .failure(.loopback)
        }
        guard let url = components.url else {
            return .failure(.invalid)
        }
        return .success(url)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalized == "localhost"
            || normalized == "::1"
            || normalized == "0:0:0:0:0:0:0:1"
            || normalized.hasPrefix("127.")
    }
}

struct AddRemoteMacSheet: View {
    @ObservedObject var model: RemoteMacsModel
    let makePairingDriver: () -> AddRemoteMacPairingDriving
    let onCancel: () -> Void
    let onPaired: () -> Void

    @State private var controller = AddRemoteMacFormController()
    @State private var errorMessage: String?
    @State private var isPairingInFlight = false
    @State private var pairingDriver: AddRemoteMacPairingDriving?
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var manualURLFieldFocused: Bool

    private var lifecycle: AddRemoteMacSheetLifecycle {
        AddRemoteMacSheetLifecycle(
            startDiscovery: { model.startDiscovery() },
            stopDiscovery: { model.stopDiscovery() }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                Text("Add Remote Mac")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Discovered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if model.discoveryCandidates.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } else {
                    ForEach(Array(model.discoveryCandidates.enumerated()), id: \.offset) { _, candidate in
                        candidateButton(candidate)
                    }
                }
            }

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("URL:")
                        .foregroundStyle(.secondary)
                    TextField("http://studio.local:9443", text: Binding(
                        get: { controller.manualURLString },
                        set: {
                            if pairingDriver != nil {
                                cancelActivePairing()
                            }
                            controller.updateManualURL($0)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($manualURLFieldFocused)
                }
            }

            if let verificationCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verification Code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(verificationCode.display)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }

            if let message = currentErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    cancelActivePairing()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    pairingTask?.cancel()
                    pairingTask = Task { await handlePrimaryAction() }
                } label: {
                    if isPairingInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(primaryActionTitle, systemImage: primaryActionIcon)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAttemptPairing || isPairingInFlight)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            lifecycle.appear()
            manualURLFieldFocused = true
        }
        .onDisappear {
            cancelActivePairing()
            lifecycle.disappear()
        }
    }

    private var verificationCode: RemoteVerificationCode? {
        if case .verifying(let code) = controller.phase {
            return code
        }
        return nil
    }

    private var currentErrorMessage: String? {
        if let errorMessage {
            return errorMessage
        }
        let trimmed = controller.manualURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if case .failure(let error) = AddRemoteMacFormController.validateManualURL(trimmed) {
            return error.message
        }
        return nil
    }

    private var canAttemptPairing: Bool {
        switch controller.phase {
        case .candidateSelected, .manualURLReady, .verifying:
            true
        case .idle, .failed:
            false
        }
    }

    private var primaryActionTitle: String {
        controller.canConfirmVerification ? "Confirm" : "Pair"
    }

    private var primaryActionIcon: String {
        controller.canConfirmVerification ? "checkmark" : "link"
    }

    @MainActor
    private func handlePrimaryAction() async {
        errorMessage = nil
        switch controller.phase {
        case .candidateSelected, .manualURLReady:
            guard let baseURL = controller.selectedPairingBaseURL else {
                errorMessage = "Select a remote Mac or enter its LAN URL."
                return
            }
            await beginPairing(baseURL: baseURL)
        case .verifying:
            await confirmPairing()
        case .idle, .failed:
            return
        }
    }

    @MainActor
    private func beginPairing(baseURL: URL) async {
        isPairingInFlight = true
        defer { isPairingInFlight = false }

        let driver = makePairingDriver()
        pairingDriver = driver
        do {
            let code = try await driver.beginPairing(baseURL: baseURL)
            try Task.checkCancellation()
            controller.showVerificationCode(code)
        } catch is CancellationError {
            driver.cancelPairing()
            if pairingDriver === driver {
                pairingDriver = nil
            }
        } catch {
            pairingDriver = nil
            controller.phase = .failed(pairingErrorMessage(error))
            errorMessage = pairingErrorMessage(error)
        }
    }

    @MainActor
    private func confirmPairing() async {
        guard let driver = pairingDriver else {
            errorMessage = "Start pairing before confirming."
            return
        }

        isPairingInFlight = true
        defer { isPairingInFlight = false }

        do {
            let pinnedHost = try await driver.confirmPairing()
            try Task.checkCancellation()
            try model.recordPairingResult(.paired(pinnedHost))
            pairingDriver = nil
            onPaired()
        } catch is CancellationError {
            driver.cancelPairing()
        } catch {
            errorMessage = pairingErrorMessage(error)
        }
    }

    @MainActor
    private func cancelActivePairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingDriver?.cancelPairing()
        pairingDriver = nil
        isPairingInFlight = false
    }

    private func pairingErrorMessage(_ error: Error) -> String {
        switch error {
        case LocalPairingClient.Error.denied:
            "Pairing was denied on the remote Mac."
        case LocalPairingClient.Error.expired:
            "Pairing expired. Start again."
        case LocalPairingClient.Error.cancelled:
            "Pairing was cancelled."
        case LocalPairingClient.Error.malformedPairingURL:
            "The remote Mac URL is not a valid pairing endpoint."
        case LocalPairingClient.Error.decode:
            "The remote Mac returned an unreadable pairing response."
        case let LocalPairingClient.Error.serverError(response):
            response.error
        case let LocalPairingClient.Error.httpStatus(status):
            "The remote Mac returned HTTP \(status)."
        case let LocalPairingClient.Error.transport(message):
            "Could not reach the remote Mac: \(message)"
        case ClientPairingSession.Error.fingerprintMismatch:
            "The host key did not match the advertised identity."
        case ClientPairingSession.Error.expired:
            "Pairing expired. Start again."
        case let ClientPairingSession.Error.unsupportedPayloadVersion(version):
            "Unsupported pairing version \(version)."
        case let ClientPairingSession.Error.pinnedHostStoreFailed(message):
            "Could not save the remote Mac: \(message)"
        default:
            "Pairing failed: \(error)"
        }
    }

    private func candidateButton(_ candidate: GrafttyBonjourCandidate) -> some View {
        let identity = RemoteMacIdentity(candidate)
        let isSelected = controller.selectedCandidateIdentity == identity
        return Button {
            errorMessage = nil
            cancelActivePairing()
            controller.selectCandidate(candidate)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "laptopcomputer")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.label)
                        .lineLimit(1)
                    Text(candidate.baseURL.host ?? candidate.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
