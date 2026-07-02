#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Observation
import SwiftUI
import UIKit

// MARK: - PairDeviceFlowModel

/// Drives one pairing ceremony from a scanned QR payload through to a
/// pinned host + saved `Host` record.
///
/// Kept separate from `PairDeviceFlowView` so the state machine is testable
/// against a stubbed `LocalPairingClient.Transport` without instantiating
/// SwiftUI or `UIDevice`.
///
/// @spec REMOTE-1.5
/// When a pairing completes with host confirmation, the client shall pin
/// the host identity and record the host device identifier on the saved
/// host entry.
@MainActor
@Observable
public final class PairDeviceFlowModel {

    // MARK: State

    public enum State: Equatable {
        /// Introduce request in flight; nothing to show the user yet.
        case connecting
        /// Host received the introduce request; waiting for the user to
        /// confirm the verification code on the Mac.
        case awaitingConfirmation(code: String, hostDisplayName: String)
        /// Host confirmed; `host` is ready to hand to the caller's `onSave`.
        /// `addressUnconfirmed` is true when the QR payload carried no
        /// `webBaseURL` (the host's web server wasn't running at pairing
        /// time), so the saved host's address is a best-effort guess.
        case success(host: Host, addressUnconfirmed: Bool)
        case denied
        case expired
        case cancelled
        case failed(message: String)
    }

    public private(set) var state: State = .connecting

    // MARK: Dependencies

    private let payload: PairingPayload
    private let session: ClientPairingSession
    private let client: LocalPairingClient

    /// The unstructured task backing the in-flight `runPairing` call.
    /// Tracked so `cancel()` can tear it down — SwiftUI's `.task` modifier
    /// only cancels the *outer* task running `run()`; it has no visibility
    /// into this inner `Task { ... }`, so without this reference a
    /// dismissed view would leak the long-poll for up to 320s (REMOTE-1.5
    /// regression: a late host confirmation would silently pin a host
    /// after the user believed they'd cancelled).
    private var pairingTask: Task<Result<PinnedHost, Swift.Error>, Never>?

    // MARK: Init

    public init(payload: PairingPayload, session: ClientPairingSession, client: LocalPairingClient) {
        self.payload = payload
        self.session = session
        self.client = client
    }

    // MARK: - Public API

    /// Runs the pairing ceremony end to end. Concurrently polls
    /// `session.state` so the UI can surface the verification code as soon
    /// as the host acknowledges the introduce request, rather than sitting
    /// on `.connecting` for the whole (up to ~300s) await-outcome long-poll.
    public func run() async {
        state = .connecting

        let pairingTask = Task { () -> Result<PinnedHost, Swift.Error> in
            do {
                return .success(try await self.client.runPairing(payload: self.payload))
            } catch {
                return .failure(error)
            }
        }
        self.pairingTask = pairingTask

        let pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reflectAwaitingConfirmation()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let result = await pairingTask.value
        self.pairingTask = nil
        pollTask.cancel()

        switch result {
        case .success(let pinnedHost):
            state = .success(
                host: Self.makeHost(payload: payload, pinnedHost: pinnedHost),
                addressUnconfirmed: payload.webBaseURL == nil
            )
        case .failure(LocalPairingClient.Error.denied):
            state = .denied
        case .failure(LocalPairingClient.Error.expired):
            state = .expired
        case .failure(LocalPairingClient.Error.cancelled):
            state = .cancelled
        // `LocalPairingClient.postJSON` maps a cancelled `Task` (and the
        // `URLError(.cancelled)` the production transport throws for one)
        // to `.cancelled` above, but guard here too in case a future
        // throwing point in the chain lets a raw `CancellationError`
        // through unwrapped — it must land on `.cancelled`, never
        // `.failed`, or `cancel()` would flash a spurious error message.
        case .failure(let error) where error is CancellationError:
            state = .cancelled
        case .failure(let error):
            state = .failed(message: "\(error)")
        }
    }

    private func reflectAwaitingConfirmation() {
        guard case .connecting = state else { return }
        guard case .awaitingHostConfirmation(_, let code, let payload) = session.state else { return }
        state = .awaitingConfirmation(code: code.display, hostDisplayName: payload.hostDisplayName)
    }

    /// Cancels an in-flight pairing ceremony.
    ///
    /// Cancels the unstructured `pairingTask` (so the host's `/await-outcome`
    /// long-poll actually tears down instead of running for up to 320s after
    /// the user has dismissed the view) and tells `session` the ceremony was
    /// cancelled, so a `confirm()` racing in from a delayed host response
    /// finds a terminal state and pins nothing.
    ///
    /// Safe to call repeatedly and after the ceremony has already reached a
    /// terminal state: `Task.cancel()` on a finished task is a no-op, and
    /// `ClientPairingSession.cancel()` no-ops from `.confirmed` and other
    /// terminal states.
    public func cancel() {
        pairingTask?.cancel()
        session.cancel()
    }

    // MARK: - Host construction

    /// Fallback web port used when the QR payload carries no `webBaseURL`
    /// (the host's web server wasn't running at pairing time). Matches
    /// `WebAccessSettings`'s default `WebAccessPort`.
    static let fallbackWebPort = 8799

    static func makeHost(payload: PairingPayload, pinnedHost: PinnedHost) -> Host {
        let baseURL = payload.webBaseURL ?? fallbackBaseURL(pairingURL: payload.pairingURL)
        return Host(
            label: payload.hostDisplayName,
            baseURL: baseURL,
            remoteDeviceID: payload.hostDeviceID
        )
    }

    private static func fallbackBaseURL(pairingURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = pairingURL.host
        components.port = fallbackWebPort
        return components.url ?? pairingURL
    }
}

// MARK: - PairDeviceFlowView

/// UI for the scan-to-pair ceremony: connecting spinner → verification code
/// → success/denied/expired/error, backed by `PairDeviceFlowModel`.
public struct PairDeviceFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PairDeviceFlowModel?
    @State private var saveError: String?

    let payload: PairingPayload
    let onSave: (Host) throws -> Void
    let onRetry: () -> Void

    public init(
        payload: PairingPayload,
        onSave: @escaping (Host) throws -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.payload = payload
        self.onSave = onSave
        self.onRetry = onRetry
    }

    public var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model?.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                guard model == nil else { return }
                let built = Self.buildModel(payload: payload)
                model = built
                await built?.run()
            }
            // Covers swipe-to-dismiss and any other disappearance path that
            // doesn't go through the toolbar button — without this, the
            // host's long-poll keeps running and a late confirmation would
            // silently pin the host after the user believed they'd left.
            .onDisappear {
                model?.cancel()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .connecting {
        case .connecting:
            connectingView
        case .awaitingConfirmation(let code, let hostDisplayName):
            awaitingConfirmationView(code: code, hostDisplayName: hostDisplayName)
        case .success(let host, let addressUnconfirmed):
            successView(host: host, addressUnconfirmed: addressUnconfirmed)
        case .denied:
            retryView(message: "Pairing was denied on your Mac.")
        case .expired:
            retryView(message: "The pairing code expired. Scan the QR code again.")
        case .cancelled:
            retryView(message: "Pairing was cancelled.")
        case .failed(let message):
            retryView(message: "Couldn't pair: \(message)")
        }
    }

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Connecting…").foregroundStyle(.secondary)
        }
    }

    private func awaitingConfirmationView(code: String, hostDisplayName: String) -> some View {
        VStack(spacing: 16) {
            Text(code)
                .font(.system(.largeTitle, design: .monospaced))
                .bold()
            Text("Confirm on \(hostDisplayName)")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func successView(host: Host, addressUnconfirmed: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(host.label)
            if addressUnconfirmed {
                Text("Verify this host's address in host settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let saveError {
                Text(saveError).foregroundStyle(.red)
            }
            Button("Done") { finish(host: host) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func retryView(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
            Button("Retry") { onRetry() }
        }
        .padding()
    }

    private func finish(host: Host) {
        do {
            try onSave(host)
            dismiss()
        } catch {
            saveError = "Couldn't save: \(error)"
        }
    }

    // MARK: - Model construction

    private static func buildModel(payload: PairingPayload) -> PairDeviceFlowModel? {
        let directory = ClientIdentityStore.defaultDirectory
        let identityStore = ClientIdentityStore(directory: directory)
        let pinnedHostStore = PinnedHostStore(directory: directory)
        let deviceIDStore = ClientDeviceIDStore(directory: directory)

        guard let clientDeviceID = try? deviceIDStore.loadOrGenerateAndPersist() else {
            return nil
        }

        let session = ClientPairingSession(
            identityStore: identityStore,
            pinnedHostStore: pinnedHostStore,
            clientDeviceID: clientDeviceID,
            clientKind: UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone,
            clientDisplayName: UIDevice.current.name
        )
        let client = LocalPairingClient(
            session: session,
            identityStore: identityStore,
            transport: Self.productionTransport
        )
        return PairDeviceFlowModel(payload: payload, session: session, client: client)
    }

    /// `nonisolated` because `PairDeviceFlowView: View` otherwise infers
    /// `@MainActor` isolation for all members (including these statics),
    /// which would make the transport function value unusable as the
    /// non-isolated `@Sendable` closure `LocalPairingClient` expects.
    /// `timeoutIntervalForRequest` must exceed the host's `await-outcome`
    /// long-poll window (`PairingProtocolDefaults.sessionValidity`, 300s)
    /// or the client will time out while the host is still legitimately
    /// waiting on the user to tap Confirm/Deny.
    nonisolated private static let productionSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = PairingProtocolDefaults.clientRequestTimeout
        return URLSession(configuration: config)
    }()

    nonisolated private static let productionTransport: LocalPairingClient.Transport = { request in
        let (data, response) = try await productionSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
#endif
