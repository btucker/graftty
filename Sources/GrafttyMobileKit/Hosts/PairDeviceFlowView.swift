#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Observation
import SwiftUI
import UIKit

// MARK: - PairDeviceFlowModel

/// Drives one pairing ceremony from a discovered or manually bootstrapped
/// payload through to a pinned host + saved `Host` record.
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
        /// `addressUnconfirmed` is retained for source compatibility with
        /// the pre-device-pairing view. The LAN pairing payload now carries
        /// the exact signaling listener, so new pairings always set it false.
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

    /// Latched by `cancel()` *before* it tears down `pairingTask`/`session`,
    /// so `run()`'s failure handling can tell "the user cancelled" apart
    /// from "the ceremony genuinely failed" even when the underlying error
    /// doesn't say so. Without this, a failure racing the teardown — e.g.
    /// `session.confirm()` losing a race with `session.cancel()` and
    /// throwing `ClientPairingSession.Error.wrongState(current: .cancelled)`
    /// — falls through to the generic `.failed` branch and flashes a
    /// spurious error message on a ceremony the user already backed out of.
    private var wasCancelled = false

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
                // Stop as soon as the code has been reflected (or the model
                // is gone) — polling on after that point wakes the timer
                // every 100ms for the rest of the ~300s await-outcome
                // long-poll for no observable benefit, since `run()`'s own
                // await on `pairingTask.value` takes over from here.
                if self?.reflectAwaitingConfirmation() ?? true { break }
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
                addressUnconfirmed: false
            )
        case .failure(LocalPairingClient.Error.denied):
            state = .denied
        case .failure(LocalPairingClient.Error.expired):
            state = .expired
        case .failure(LocalPairingClient.Error.cancelled):
            state = .cancelled
        // `wasCancelled` is checked before the generic `.failed` fallback
        // so any error surfacing after the user cancelled — regardless of
        // its concrete type — presents as `.cancelled` rather than a
        // spurious failure message. See `wasCancelled`'s doc comment.
        case .failure where wasCancelled:
            state = .cancelled
        case .failure(let error):
            state = .failed(message: "\(error)")
        }
    }

    /// Returns `true` once there's nothing left for the poll loop to do:
    /// either it just reflected `.awaitingConfirmation`, or `state` has
    /// already moved past `.connecting` for some other reason (e.g. the
    /// ceremony failed outright before the host ever acknowledged it).
    @discardableResult
    private func reflectAwaitingConfirmation() -> Bool {
        guard case .connecting = state else { return true }
        guard case .awaitingHostConfirmation(_, let code, let payload) = session.state else { return false }
        state = .awaitingConfirmation(code: code.display, hostDisplayName: payload.hostDisplayName)
        return true
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
        wasCancelled = true
        pairingTask?.cancel()
        session.cancel()
    }

    // MARK: - Host construction

    static func makeHost(payload: PairingPayload, pinnedHost: PinnedHost) -> Host {
        // New Bonjour-initiated pairing payloads have no `webBaseURL`; their
        // pairing URL is rooted at the durable (for this host process) LAN
        // pairing/signaling listener. Older QR payloads retain their Web
        // Access URL as a compatibility path.
        let baseURL = payload.webBaseURL ?? pairingBaseURL(payload.pairingURL)
        return Host(
            label: payload.hostDisplayName,
            baseURL: baseURL,
            remoteDeviceID: payload.hostDeviceID
        )
    }

    private static func pairingBaseURL(_ pairingURL: URL) -> URL {
        guard var components = URLComponents(
            url: pairingURL,
            resolvingAgainstBaseURL: false
        ) else {
            return pairingURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
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
    /// True when `buildModel` returned `nil` (e.g. `ClientDeviceIDStore`
    /// couldn't read/persist an identity). Tracked separately from `model`
    /// because a nil model is otherwise indistinguishable from "hasn't
    /// started yet" — without this, `content` falls through to
    /// `connectingView` forever, an infinite spinner with no way out.
    @State private var buildFailed = false

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
                await start()
            }
            // Covers swipe-to-dismiss and any other disappearance path that
            // doesn't go through the toolbar button — without this, the
            // host's long-poll keeps running and a late confirmation would
            // silently pin the host after the user believed they'd left.
            .onDisappear {
                model?.cancel()
            }
    }

    private func start() async {
        guard model == nil else { return }
        guard let built = Self.buildModel(payload: payload) else {
            buildFailed = true
            return
        }
        buildFailed = false
        model = built
        await built.run()
    }

    /// Retries from a `buildModel` failure — distinct from `onRetry`, which
    /// backs out to the nearby-Mac picker. A broken `ClientDeviceIDStore`
    /// won't be fixed by rediscovering the same host, so this re-attempts
    /// `buildModel` in place instead.
    private func retryBuild() {
        buildFailed = false
        Task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        if buildFailed {
            retryView(message: "Couldn't start pairing. Try again.", onRetry: retryBuild)
        } else {
            switch model?.state ?? .connecting {
            case .connecting:
                connectingView
            case .awaitingConfirmation(let code, let hostDisplayName):
                awaitingConfirmationView(code: code, hostDisplayName: hostDisplayName)
            case .success(let host, let addressUnconfirmed):
                successView(host: host, addressUnconfirmed: addressUnconfirmed)
            case .denied:
                retryView(message: "Pairing was denied on your Mac.", onRetry: onRetry)
            case .expired:
                retryView(message: "The pairing code expired. Start pairing again.", onRetry: onRetry)
            case .cancelled:
                retryView(message: "Pairing was cancelled.", onRetry: onRetry)
            case .failed(let message):
                retryView(message: "Couldn't pair: \(message)", onRetry: onRetry)
            }
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

    private func retryView(message: String, onRetry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(message)
            Button("Retry", action: onRetry)
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

    // MARK: - Model construction (unit-testable, no SwiftUI/View state)

    /// `directory` is injectable so tests can force `ClientDeviceIDStore`'s
    /// underlying I/O to fail (e.g. by pointing it at a path a file already
    /// occupies) without touching the production `defaultDirectory`.
    static func buildModel(
        payload: PairingPayload,
        directory: URL = ClientIdentityStore.defaultDirectory
    ) -> PairDeviceFlowModel? {
        let stores = ClientRemoteStores(directory: directory)

        guard let clientDeviceID = try? stores.deviceIDStore.loadOrGenerateAndPersist() else {
            return nil
        }

        let session = ClientPairingSession(
            identityStore: stores.identityStore,
            pinnedHostStore: stores.pinnedHostStore,
            clientDeviceID: clientDeviceID,
            clientKind: UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone,
            clientDisplayName: UIDevice.current.name
        )
        let client = LocalPairingClient(
            session: session,
            identityStore: stores.identityStore,
            transport: Self.productionTransport
        )
        return PairDeviceFlowModel(payload: payload, session: session, client: client)
    }

    /// Starts the Bonjour/manual-address pairing bootstrap and returns the
    /// host-authenticated payload used by the existing ceremony view.
    static func beginPairing(
        baseURL: URL,
        directory: URL = ClientIdentityStore.defaultDirectory
    ) async throws -> PairingPayload {
        let stores = ClientRemoteStores(directory: directory)
        let clientDeviceID = try stores.deviceIDStore
            .loadOrGenerateAndPersist()
        let session = ClientPairingSession(
            identityStore: stores.identityStore,
            pinnedHostStore: stores.pinnedHostStore,
            clientDeviceID: clientDeviceID,
            clientKind: UIDevice.current.userInterfaceIdiom == .pad
                ? .ipad
                : .iphone,
            clientDisplayName: UIDevice.current.name
        )
        let client = LocalPairingClient(
            session: session,
            identityStore: stores.identityStore,
            transport: productionTransport
        )
        return try await client.beginPairing(baseURL: baseURL)
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
