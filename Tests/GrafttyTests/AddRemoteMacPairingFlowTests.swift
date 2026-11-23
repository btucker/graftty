import CryptoKit
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

@testable import Graftty
@testable import GrafttyKit

@Suite("Add Remote Mac pairing flow")
@MainActor
struct AddRemoteMacPairingFlowTests {
    @Test("@spec REMOTE-1.19: When the user changes the pairing target while a verification code is showing, the application shall cancel that pairing and remove the code, so the next primary action starts a new pairing instead of confirming one that no longer exists.")
    func changingTheTargetEndsAShownVerification() async throws {
        let harness = try Harness()
        try await harness.reachVerification()
        harness.flow.updateManualURL("not a url")
        #expect(harness.flow.verificationCode == nil)
        #expect(!harness.flow.isAwaitingConfirmation)
        #expect(harness.drivers[0].cancelCount == 1)
        // The discovered Mac is still selected, so pairing can start again.
        #expect(harness.flow.canRunPrimaryAction)
        harness.flow.runPrimaryAction()
        #expect(harness.drivers.count == 2)
        #expect(harness.flow.isInFlight)
    }

    @Test func confirmingRecordsTheHostAndFinishes() async throws {
        let harness = try Harness()
        try await harness.reachVerification()
        harness.flow.runPrimaryAction()
        #expect(harness.flow.isInFlight)
        #expect(harness.flow.verificationCode == Harness.code)
        harness.drivers[0].confirm.resume(returning: try Harness.host())
        try await harness.until { harness.paired == 1 }
        #expect(harness.recorded.map(\.id.value) == ["studio-mac"])
        #expect(!harness.flow.isInFlight)
    }

    @Test func failureShowsItsMessageUntilTheTargetChanges() async throws {
        let harness = try Harness()
        harness.flow.selectCandidate(try Harness.candidate())
        harness.flow.runPrimaryAction()
        harness.drivers[0].begin.resume(throwing: LocalPairingClient.Error.denied)
        try await harness.until { harness.flow.failureMessage != nil }
        #expect(harness.flow.failureMessage == "Pairing was denied on the remote Mac.")
        #expect(!harness.flow.canRunPrimaryAction)
        harness.flow.selectCandidate(try Harness.candidate())
        #expect(harness.flow.failureMessage == nil)
        #expect(harness.flow.canRunPrimaryAction)
    }

    @Test func cancelledBeginIgnoresALateCode() async throws {
        let harness = try Harness()
        harness.flow.selectCandidate(try Harness.candidate())
        harness.flow.runPrimaryAction()
        harness.flow.cancel()
        #expect(harness.drivers[0].cancelCount == 1)
        harness.drivers[0].begin.resume(returning: Harness.code)
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.flow.verificationCode == nil)
        #expect(!harness.flow.isInFlight)
    }

    @Test func pairingCancelledByTheHostReturnsToTheForm() async throws {
        let harness = try Harness()
        try await harness.reachVerification()
        harness.flow.runPrimaryAction()
        harness.drivers[0].confirm.resume(throwing: LocalPairingClient.Error.cancelled)
        try await harness.until { !harness.flow.isInFlight }
        #expect(harness.flow.verificationCode == nil)
        #expect(harness.flow.failureMessage == nil)
        #expect(harness.flow.canRunPrimaryAction)
        #expect(harness.paired == 0)
    }
}

@MainActor
private final class Harness {
    static let code = RemoteVerificationCode(digits: "123456")
    var drivers: [FakePairingDriver] = []
    var recorded: [PinnedHost] = []
    var paired = 0
    private(set) var flow: AddRemoteMacPairingFlow!

    init() throws {
        flow = AddRemoteMacPairingFlow(
            makeDriver: { [unowned self] in
                let driver = FakePairingDriver()
                self.drivers.append(driver)
                return driver
            },
            record: { [unowned self] host, _, _ in self.recorded.append(host) },
            onPaired: { [unowned self] in self.paired += 1 }
        )
    }

    static func candidate() throws -> GrafttyBonjourCandidate {
        GrafttyBonjourCandidate(
            deviceID: RemoteDeviceID(value: "studio-mac"), label: "Studio Mac",
            fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0x22, count: 32)),
            baseURL: URL(string: "http://studio.local:9443")!,
            protocolVersion: GrafttyBonjourService.discoveryVersion, pairingStatus: .required,
            discoveredAt: Date(timeIntervalSince1970: 1_720_000_000))
    }

    static func host() throws -> PinnedHost {
        PinnedHost(id: RemoteDeviceID(value: "studio-mac"), kind: .mac,
                   publicKey: try RemoteIdentityPublicKey(rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation),
                   displayName: "Studio Mac", pinnedAt: Date(timeIntervalSince1970: 1_720_000_000),
                   pairingURL: URL(string: "http://studio.local:9443")!)
    }

    /// Selects a discovered Mac and pairs until its code is showing.
    func reachVerification() async throws {
        flow.selectCandidate(try Self.candidate())
        flow.runPrimaryAction()
        drivers[0].begin.resume(returning: Self.code)
        try await until { self.flow.isAwaitingConfirmation }
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
        try #require(condition())
    }
}

/// Each call parks until the test resumes it.
@MainActor
private final class FakePairingDriver: AddRemoteMacPairingDriving {
    let begin = Gate<RemoteVerificationCode>()
    let confirm = Gate<PinnedHost>()
    nonisolated(unsafe) var cancelCount = 0

    nonisolated func beginPairing(baseURL: URL) async throws -> RemoteVerificationCode { try await begin.value() }
    nonisolated func confirmPairing() async throws -> PinnedHost { try await confirm.value() }
    nonisolated func cancelPairing() { cancelCount += 1 }
}

@MainActor
private final class Gate<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiter: CheckedContinuation<Value, any Error>?

    func value() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func resume(returning value: Value) { resume(.success(value)) }
    func resume(throwing error: any Error) { resume(.failure(error)) }
    private func resume(_ result: Result<Value, any Error>) {
        self.result = result
        waiter?.resume(with: result)
        waiter = nil
    }
}
