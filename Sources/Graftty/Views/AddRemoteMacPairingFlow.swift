import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

/// The Add Remote Mac sheet's form and the pairing it starts.
///
/// `pairing` is the ceremony's whole lifecycle. Each step holds the driver it
/// talks to, so a verification code is never shown without a pairing behind it.
@MainActor
final class AddRemoteMacPairingFlow: ObservableObject {
    typealias Driver = any AddRemoteMacPairingDriving

    private enum Pairing {
        case idle
        /// Asking the remote Mac for a verification code.
        case beginning(Driver, Task<Void, Never>)
        /// The code is showing; the user compares it and confirms.
        case verifying(RemoteVerificationCode, Driver)
        /// Waiting for the remote Mac to accept.
        case confirming(RemoteVerificationCode, Driver, Task<Void, Never>)
        /// Pairing cannot start again until the user changes the target.
        case failed(String)
    }

    /// Edit the target through `selectCandidate` and `updateManualURL`.
    @Published var form = AddRemoteMacFormController()
    @Published private var pairing = Pairing.idle

    private let makeDriver: () throws -> Driver
    private let record: (PinnedHost, RemoteHostTransport, DirectSSHEndpoint?) throws -> Void
    private let onPaired: () -> Void

    init(
        makeDriver: @escaping () throws -> Driver,
        record: @escaping (PinnedHost, RemoteHostTransport, DirectSSHEndpoint?) throws -> Void,
        onPaired: @escaping () -> Void
    ) {
        self.makeDriver = makeDriver
        self.record = record
        self.onPaired = onPaired
    }

    var verificationCode: RemoteVerificationCode? {
        switch pairing {
        case .verifying(let code, _), .confirming(let code, _, _): code
        case .idle, .beginning, .failed: nil
        }
    }

    var isInFlight: Bool {
        switch pairing {
        case .beginning, .confirming: true
        case .idle, .verifying, .failed: false
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = pairing { return message }
        return nil
    }

    /// Whether the primary button confirms a shown code rather than starting.
    var isAwaitingConfirmation: Bool {
        if case .verifying = pairing { return true }
        return false
    }

    /// The connection settings are fixed once a pairing has started.
    var locksConnection: Bool { isInFlight || isAwaitingConfirmation }

    var canRunPrimaryAction: Bool {
        if form.transport == .directSSH, (try? form.directEndpoint()) == nil { return false }
        switch pairing {
        case .idle: return form.selectedPairingBaseURL != nil
        case .verifying: return true
        case .beginning, .confirming, .failed: return false
        }
    }

    func selectCandidate(_ candidate: GrafttyBonjourCandidate) {
        cancel()
        form.selectCandidate(candidate)
    }

    func updateManualURL(_ value: String) {
        cancel()
        form.updateManualURL(value)
    }

    /// Starts pairing with the chosen target, or confirms the shown code.
    func runPrimaryAction() {
        guard canRunPrimaryAction else { return }
        switch pairing {
        case .idle:
            guard let baseURL = form.selectedPairingBaseURL else { return }
            begin(baseURL: baseURL)
        case .verifying(let code, let driver):
            confirm(code, with: driver)
        case .beginning, .confirming, .failed:
            return
        }
    }

    /// Abandons any pairing and clears a failure.
    func cancel() {
        switch pairing {
        case .idle:
            return
        case .beginning(let driver, let task), .confirming(_, let driver, let task):
            task.cancel()
            driver.cancelPairing()
        case .verifying(_, let driver):
            driver.cancelPairing()
        case .failed:
            break
        }
        pairing = .idle
    }

    private func begin(baseURL: URL) {
        let driver: Driver
        do { driver = try makeDriver() } catch {
            pairing = .failed(Self.message(for: error))
            return
        }
        let task = Task { [weak self] in
            let result: Result<RemoteVerificationCode, any Error>
            do { result = .success(try await driver.beginPairing(baseURL: baseURL)) } catch { result = .failure(error) }
            self?.finishBeginning(driver, result)
        }
        pairing = .beginning(driver, task)
    }

    private func finishBeginning(_ driver: Driver, _ result: Result<RemoteVerificationCode, any Error>) {
        guard case .beginning(let current, _) = pairing, current === driver else { return }
        switch result {
        case .success(let code): pairing = .verifying(code, driver)
        case .failure(let error): fail(error, driver: driver)
        }
    }

    private func confirm(_ code: RemoteVerificationCode, with driver: Driver) {
        let task = Task { [weak self] in
            let result: Result<PinnedHost, any Error>
            do { result = .success(try await driver.confirmPairing()) } catch { result = .failure(error) }
            self?.finishConfirming(driver, result)
        }
        pairing = .confirming(code, driver, task)
    }

    private func finishConfirming(_ driver: Driver, _ result: Result<PinnedHost, any Error>) {
        let isCurrent = if case .confirming(_, let current, _) = pairing { current === driver } else { false }
        do {
            // The host is already pinned, so save it even if the sheet moved on.
            let host = try result.get()
            try record(host, form.transport, form.transport == .directSSH ? try form.directEndpoint() : nil)
            guard isCurrent else { return }
            pairing = .idle
            onPaired()
        } catch {
            if isCurrent { fail(error, driver: driver) }
        }
    }

    /// A cancelled pairing returns to the form; any other error stays on
    /// screen. The driver is spent either way.
    private func fail(_ error: any Error, driver: Driver) {
        if error is CancellationError || (error as? LocalPairingClient.Error) == .cancelled {
            driver.cancelPairing()
            pairing = .idle
        } else {
            pairing = .failed(Self.message(for: error))
        }
    }

    static func message(for error: any Error) -> String {
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
}
