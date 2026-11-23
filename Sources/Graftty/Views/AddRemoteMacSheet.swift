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
    private var activePayload: PairingPayload?

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
        activePayload = payload
        try Task.checkCancellation()
        return try await client.introduce(payload: payload)
    }

    func confirmPairing() async throws -> PinnedHost {
        let host = try await client.awaitOutcomeAndConfirm()
        activePayload = nil
        return host
    }

    func cancelPairing() {
        session.cancel()
        guard let payload = activePayload else { return }
        activePayload = nil
        let client = client
        Task {
            await client.cancelPairing(payload: payload)
        }
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

    var transport: RemoteHostTransport = .webRTC
    var directHostString = ""
    var directPortString = "8801"
    var manualURLString: String = ""
    var selectedCandidateIdentity: RemoteMacIdentity?
    var selectedPairingBaseURL: URL?
    var phase: Phase = .idle

    func directEndpoint() throws -> DirectSSHEndpoint {
        let host = directHostString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(directPortString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DirectSSHEndpoint.ValidationError.invalidPort
        }
        return try DirectSSHEndpoint(host: host.isEmpty ? (selectedPairingBaseURL?.host ?? "") : host, port: port)
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
    let onCancel: () -> Void

    @StateObject private var flow: AddRemoteMacPairingFlow
    @FocusState private var manualURLFieldFocused: Bool

    init(
        model: RemoteMacsModel,
        makePairingDriver: @escaping () throws -> AddRemoteMacPairingDriving,
        onCancel: @escaping () -> Void,
        onPaired: @escaping () -> Void
    ) {
        self.model = model
        self.onCancel = onCancel
        _flow = StateObject(wrappedValue: AddRemoteMacPairingFlow(
            makeDriver: makePairingDriver,
            record: { try model.recordPairingResult(.paired($0), transport: $1, directEndpoint: $2) },
            onPaired: onPaired
        ))
    }

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
                        get: { flow.form.manualURLString },
                        // Editing the target ends any pairing and clears a
                        // stale pairing error, so live validation shows through.
                        set: { flow.updateManualURL($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($manualURLFieldFocused)
                }
            }

            Picker("Connection", selection: $flow.form.transport) {
                Text("WebRTC").tag(RemoteHostTransport.webRTC)
                Text("Direct SSH").tag(RemoteHostTransport.directSSH)
            }
            .pickerStyle(.segmented)
            .disabled(flow.locksConnection)

            if flow.form.transport == .directSSH {
                HStack {
                    TextField("Graftty host", text: $flow.form.directHostString)
                    TextField("8801", text: $flow.form.directPortString)
                        .frame(width: 70)
                }
                .textFieldStyle(.roundedBorder)
                .disabled(flow.locksConnection)
                Text("Connect to the Graftty SSH service. Default port 8801. The pairing URL above is used to verify the host first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let verificationCode = flow.verificationCode {
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
                    flow.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    flow.runPrimaryAction()
                } label: {
                    if flow.isInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(primaryActionTitle, systemImage: primaryActionIcon)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canRunPrimaryAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            lifecycle.appear()
            manualURLFieldFocused = true
        }
        .onDisappear {
            flow.cancel()
            lifecycle.disappear()
        }
    }

    private var currentErrorMessage: String? {
        if let message = flow.failureMessage { return message }
        let form = flow.form
        if form.transport == .directSSH, (try? form.directEndpoint()) == nil,
           form.selectedPairingBaseURL != nil {
            return "Enter a Graftty host and a port from 1 to 65535."
        }
        // A selected discovered candidate takes precedence over the manual
        // URL field, so stray/invalid text there is ignored — don't surface a
        // validation error while the Pair button will actually use the candidate.
        guard form.selectedCandidateIdentity == nil else { return nil }
        let trimmed = form.manualURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if case .failure(let error) = AddRemoteMacFormController.validateManualURL(trimmed) {
            return error.message
        }
        return nil
    }

    private var primaryActionTitle: String {
        flow.isAwaitingConfirmation ? "Confirm" : "Pair"
    }

    private var primaryActionIcon: String {
        flow.isAwaitingConfirmation ? "checkmark" : "link"
    }

    private func candidateButton(_ candidate: GrafttyBonjourCandidate) -> some View {
        let identity = RemoteMacIdentity(candidate)
        let isSelected = flow.form.selectedCandidateIdentity == identity
        return Button {
            flow.selectCandidate(candidate)
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
