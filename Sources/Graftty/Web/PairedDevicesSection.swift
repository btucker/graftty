import SwiftUI
import GrafttyKit
import GrafttyProtocol

// MARK: - PairingCountdownFormatter

/// Formats the time remaining until a pairing session's `expiry` as
/// `m:ss` (e.g. `"4:32"`), clamped to `"0:00"` once expiry has passed.
/// Kept pure (no `Date()` default beyond an injectable `now`) so it's
/// unit-testable without SwiftUI.
enum PairingCountdownFormatter {
    static func remainingLabel(untilExpiry expiry: Date, now: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now).rounded(.up)))
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - RemoteDeviceKind + display

extension RemoteDeviceKind {
    /// Human-readable label shown in pairing / paired-device UI.
    var displayLabel: String {
        switch self {
        case .mac: return "Mac"
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        }
    }
}

// MARK: - PairingSectionDisplay

/// Pure mapping from `HostPairingSessionState` to the branch of UI
/// `PairedDevicesSection` renders. Kept separate from the view body so
/// the state → branch decision is unit-testable without SwiftUI.
///
/// `.cancelled` maps to `.idle` (rather than getting its own message)
/// because cancelling is a user-initiated dismissal, not a failure
/// worth narrating — the settings pane should just look like nothing
/// happened. `.confirmed` gets its own case even though it's terminal
/// because the view shows a distinct success row before auto-returning
/// to `.idle`.
enum PairingSectionDisplay: Equatable {
    case idle
    case awaitingClient(payload: PairingPayload, expiry: Date)
    case pendingConfirmation(
        clientDisplayName: String,
        clientKind: RemoteDeviceKind,
        verificationCode: RemoteVerificationCode
    )
    case confirmedSuccess(peerDisplayName: String)
    case terminalMessage(String)

    static func mapping(for state: HostPairingSessionState) -> PairingSectionDisplay {
        switch state {
        case .idle, .cancelled:
            return .idle
        case let .awaitingClient(payload, expiry):
            return .awaitingClient(payload: payload, expiry: expiry)
        case let .pendingConfirmation(_, _, clientKind, clientDisplayName, _, verificationCode, _):
            return .pendingConfirmation(
                clientDisplayName: clientDisplayName,
                clientKind: clientKind,
                verificationCode: verificationCode
            )
        case let .confirmed(trustedPeer):
            return .confirmedSuccess(peerDisplayName: trustedPeer.displayName)
        case .denied:
            return .terminalMessage("Pairing request denied.")
        case .expired:
            return .terminalMessage("Pairing session expired before it completed.")
        case let .failed(message):
            return .terminalMessage(message)
        }
    }
}

// MARK: - PairedDevicesSection

/// Device Pairing settings-pane section: the pairing ceremony (QR →
/// verification code → confirm/deny) plus the list of already-paired
/// devices. Split out of `WebSettingsPane` (already long) per the
/// Task 3 brief.
struct PairedDevicesSection: View {
    @EnvironmentObject private var coordinator: HostPairingCoordinator
    let trustedPeerStore: TrustedPeerStore

    @State private var peers: [TrustedPeer] = []
    @State private var listError: String?

    /// Guards against a double-tap starting two overlapping listeners:
    /// `beginPairing()` has no reentrancy guard of its own (there is a
    /// window between the tap and `coordinator.state` actually leaving
    /// `.idle` while the listener socket is binding), so the button
    /// disables itself for the duration of the call.
    @State private var isStartingPairing = false

    /// Local UI-only override: once true, the idle/list branch renders
    /// even though `coordinator.state` is still `.confirmed`. The
    /// coordinator never resets `state` back to `.idle` after a terminal
    /// state (only a fresh `beginPairing()` call replaces it), so
    /// returning to the idle screen after a successful pairing is this
    /// view's responsibility, not the coordinator's.
    @State private var dismissedTerminalState = false

    private var display: PairingSectionDisplay {
        dismissedTerminalState ? .idle : PairingSectionDisplay.mapping(for: coordinator.state)
    }

    var body: some View {
        Section {
            switch display {
            case .idle:
                idleContent
            case let .awaitingClient(payload, expiry):
                awaitingClientContent(payload: payload, expiry: expiry)
            case let .pendingConfirmation(clientDisplayName, clientKind, verificationCode):
                pendingConfirmationContent(
                    clientDisplayName: clientDisplayName,
                    clientKind: clientKind,
                    verificationCode: verificationCode
                )
            case let .confirmedSuccess(peerDisplayName):
                confirmedContent(peerDisplayName: peerDisplayName)
            case let .terminalMessage(message):
                terminalContent(message: message)
            }
        } header: {
            Text("Device Pairing")
        }
        .onAppear { refreshPeers() }
        .onChange(of: coordinator.state) { _, _ in
            dismissedTerminalState = false
        }
        .onDisappear {
            // Teardown must not rely on the coordinator's 1s tick — if the
            // settings window closes (or this tab is dismissed) mid-flow,
            // end the session synchronously here so the pairing listener
            // doesn't linger (REMOTE-1.4).
            Task { await coordinator.endPairing() }
        }
    }

    // MARK: - idle / list

    @ViewBuilder private var idleContent: some View {
        Button("Pair a Device…") { startPairing() }
            .disabled(isStartingPairing)
        if let coordinatorError = coordinator.lastError {
            Text(coordinatorError).foregroundStyle(.red).font(.caption)
        }
        if let listError {
            Text(listError).foregroundStyle(.red).font(.caption)
        }
        if peers.isEmpty {
            Text("No paired devices yet.")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            ForEach(peers) { peer in
                peerRow(peer)
            }
        }
    }

    @ViewBuilder private func peerRow(_ peer: TrustedPeer) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                Text("\(peer.kind.displayLabel) · \(peer.fingerprint.display)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Paired \(Self.relativeFormatter.localizedString(for: peer.pairedAt, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { remove(peer) }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - awaitingClient

    @ViewBuilder private func awaitingClientContent(payload: PairingPayload, expiry: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                qrCode(for: payload)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan with Graftty on your phone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Expires in \(PairingCountdownFormatter.remainingLabel(untilExpiry: expiry, now: context.date))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Button("Cancel", role: .cancel) {
                Task { await coordinator.endPairing() }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func qrCode(for payload: PairingPayload) -> some View {
        // `qrEncoded()` only throws on JSON-encoding failure, which
        // shouldn't happen for a payload this type already constructed —
        // fall back to an error string rather than crash if it ever does.
        if let encoded = try? payload.qrEncoded() {
            QRCodeView(text: encoded, size: 200)
        } else {
            Text("Could not render QR code.")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    // MARK: - pendingConfirmation

    @ViewBuilder private func pendingConfirmationContent(
        clientDisplayName: String,
        clientKind: RemoteDeviceKind,
        verificationCode: RemoteVerificationCode
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(clientDisplayName) (\(clientKind.displayLabel)) wants to pair.")
            Text(verificationCode.display)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            Text("Confirm this code matches the one shown on the device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let coordinatorError = coordinator.lastError {
                Text(coordinatorError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            HStack {
                Button("Deny", role: .destructive) {
                    Task { await coordinator.deny() }
                }
                Button("Confirm") {
                    Task {
                        await coordinator.confirm()
                        refreshPeers()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - confirmed

    @ViewBuilder private func confirmedContent(peerDisplayName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Paired with \(peerDisplayName).")
        }
        .padding(.vertical, 4)
        .task {
            // Auto-return to the idle/list screen once the coordinator's
            // own tick task has had a chance to observe the terminal
            // state and tear the listener down (it ticks every 1s).
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            refreshPeers()
            dismissedTerminalState = true
        }
    }

    // MARK: - terminal (denied / expired / failed)

    @ViewBuilder private func terminalContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).foregroundStyle(.secondary)
            Button("Start Over") { startPairing() }
                .disabled(isStartingPairing)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func startPairing() {
        guard !isStartingPairing else { return }
        isStartingPairing = true
        dismissedTerminalState = false
        Task {
            await coordinator.beginPairing()
            isStartingPairing = false
        }
    }

    private func remove(_ peer: TrustedPeer) {
        do {
            try trustedPeerStore.remove(id: peer.id)
            refreshPeers()
        } catch {
            listError = "Could not remove device: \(error)"
        }
    }

    private func refreshPeers() {
        do {
            peers = try trustedPeerStore.list()
            listError = nil
        } catch {
            listError = "Could not load paired devices: \(error)"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
