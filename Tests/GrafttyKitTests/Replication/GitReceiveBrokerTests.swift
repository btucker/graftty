import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

private final class ReceiveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance() { lock.withLock { instant += .seconds(31) } }
}

@Suite
struct GitReceiveBrokerTests {
    @Test func replicationPermissionRequiresAnExplicitGrant() throws {
        let legacy = Data(#"{"terminalControl":"allowed","portTunnel":"disabled","screenView":"disabled","screenControl":"disabled","worktreeManagement":"allowed"}"#.utf8)
        #expect(try JSONDecoder().decode(PairedDeviceCapabilities.self, from: legacy).replication == .disabled)
        #expect(PairedDeviceCapabilities.defaultsAfterPairing.replication == .disabled)
        var granted = PairedDeviceCapabilities.defaultsAfterPairing
        granted.replication = .allowed
        #expect(try JSONDecoder().decode(PairedDeviceCapabilities.self, from: JSONEncoder().encode(granted)).replication == .allowed)
    }

    private struct Fixture {
        let root = URL.temporaryDirectory.appendingPathComponent("receive-broker-\(UUID())")
        let peer: RemoteMacConnectionSummary.ID
        let delegation: GitDelegation
        var store: GitDelegationStore { .init(directory: root.appendingPathComponent("authority")) }
        var scope: GitDelegationScope {
            .init(delegationID: delegation.id, generation: delegation.generation, repositoryID: delegation.repositoryID,
                  remoteWorktreeID: delegation.remoteWorktreeID, refs: delegation.allowedRefs)
        }
        init() throws {
            peer = .init(deviceID: .init(value: "worker"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
            delegation = .init(id: UUID(), generation: 1, repositoryID: UUID(), host: peer,
                remoteWorktreeID: "/project/task", allowedRefs: ["refs/heads/task"], expiresAt: Date().addingTimeInterval(600))
            try store.install(delegation)
        }
        func command() throws -> GitReceiveCommand {
            let hooks = root.appendingPathComponent("receive-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            return .init(repository: root.appendingPathComponent("repository.git"), hooksDirectory: hooks,
                         arguments: [], environment: [:])
        }
        func request() throws -> Data { try JSONEncoder().encode(GitReplicationRequest.prepareReceive(scope: scope, objectFormat: .sha1)) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func token(_ response: GitReplicationResponse) throws -> UUID {
        guard case .receiveReady(let token, let seconds) = response else {
            Issue.record("Expected prepared receiver, got \(response)")
            throw GitReplicationError.unavailable
        }
        #expect(seconds == GitReceiveBroker.validForSeconds)
        return token
    }

    @Test("@spec REMOTE-26.17: When a parent prepares a Git transfer, the application shall issue a bounded, short-lived, single-use receive token, bind it to the authenticated host and current delegation, and recheck authority before releasing its receive command.")
    func tokensRequireExactPeerCurrentAuthorityAndSingleClaim() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let command = try f.command()
        let broker = GitReceiveBroker(delegations: f.store) { _, _, _ in command }
        let bytes = try f.request()
        let wrongKey = RemoteMacConnectionSummary.ID(deviceID: f.peer.deviceID, fingerprint: try .init(rawBytes: Data(repeating: 2, count: 32)))
        let wrongDevice = RemoteMacConnectionSummary.ID(deviceID: .init(value: "other"), fingerprint: f.peer.fingerprint)
        #expect(await broker.handle(bytes, authenticatedPeer: wrongKey) == .error(.unauthorized))
        let first = try token(await broker.handle(bytes, authenticatedPeer: f.peer))
        for wrong in [wrongKey, wrongDevice] {
            await #expect(throws: (any Error).self) { try await broker.claim(first, authenticatedPeer: wrong) }
        }
        #expect(try await broker.claim(first, authenticatedPeer: f.peer).hooksDirectory == command.hooksDirectory)
        await #expect(throws: GitReplicationError.invalidToken) { try await broker.claim(first, authenticatedPeer: f.peer) }
        // Claim transfers ownership: broker shutdown must not remove a live hook.
        await broker.close()
        #expect(FileManager.default.fileExists(atPath: command.hooksDirectory.path))
        #expect(await broker.handle(bytes, authenticatedPeer: f.peer) == .error(.unavailable))

        let secondBroker = GitReceiveBroker(delegations: f.store) { _, _, _ in try f.command() }
        let second = try token(await secondBroker.handle(bytes, authenticatedPeer: f.peer))
        try f.store.revoke(id: f.delegation.id, generation: 1)
        await #expect(throws: (any Error).self) { try await secondBroker.claim(second, authenticatedPeer: f.peer) }
        await secondBroker.close()
    }

    @Test func malformedAndUnauthorizedRequestsNeverPrepareStorage() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let broker = GitReceiveBroker(delegations: f.store) { _, _, _ in
            Issue.record("Invalid request reached receiver preparation")
            throw GitReplicationError.unavailable
        }
        for bytes in [Data(), Data("{}".utf8), Data(repeating: 0x20, count: GitReceiveBroker.maximumRequestBytes + 1)] {
            #expect(await broker.handle(bytes, authenticatedPeer: f.peer) == .error(.invalidRequest))
        }
        try f.store.revoke(id: f.delegation.id, generation: 1)
        #expect(await broker.handle(try f.request(), authenticatedPeer: f.peer) == .error(.unauthorized))
        await broker.close()
    }

    @Test func expiryAndCapacityReleaseOnlyUnclaimedContexts() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let clock = ReceiveClock()
        let broker = GitReceiveBroker(delegations: f.store, now: { clock.now() }) { _, _, _ in try f.command() }
        let request = try f.request()
        var tokens: [UUID] = []
        for _ in 0..<GitReceiveBroker.maximumPending {
            tokens.append(try token(await broker.handle(request, authenticatedPeer: f.peer)))
        }
        #expect(await broker.handle(request, authenticatedPeer: f.peer) == .error(.busy))
        let claimed = try await broker.claim(tokens.removeFirst(), authenticatedPeer: f.peer)
        tokens.append(try token(await broker.handle(request, authenticatedPeer: f.peer)))
        clock.advance()
        await #expect(throws: GitReplicationError.invalidToken) { try await broker.claim(tokens[0], authenticatedPeer: f.peer) }
        let remaining = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("receive-") }
        #expect(remaining.map { $0.resolvingSymlinksInPath() } == [claimed.hooksDirectory.resolvingSymlinksInPath()])
        _ = try token(await broker.handle(request, authenticatedPeer: f.peer))
        await broker.close()
        #expect(FileManager.default.fileExists(atPath: claimed.hooksDirectory.path))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["revoked", "canceled", "closed"])
    func preparationRechecksAfterSuspensionAndCleansUnusedHook(mode: String) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let command = try f.command()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (resume, resumePreparation) = AsyncStream<Void>.makeStream()
        let broker = GitReceiveBroker(delegations: f.store) { _, _, _ in
            if mode == "revoked" { try f.store.revoke(id: f.delegation.id, generation: 1) }
            if mode == "canceled" { withUnsafeCurrentTask { $0?.cancel() } }
            if mode == "closed" {
                didStart.yield(())
                for await _ in resume { break }
            }
            return command
        }
        let request = try f.request()
        let task = Task { await broker.handle(request, authenticatedPeer: f.peer) }
        if mode == "closed" {
            for await _ in started { break }
            await broker.close()
            resumePreparation.yield(())
        }
        let response = await task.value
        #expect(response == .error(mode == "revoked" ? .unauthorized : .unavailable))
        #expect(!FileManager.default.fileExists(atPath: command.hooksDirectory.path))
        await broker.close()
    }

    @Test func simultaneousPreparationCountsAgainstCapacity() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let broker = GitReceiveBroker(delegations: f.store) { _, _, _ in
            await Task.yield()
            return try f.command()
        }
        let request = try f.request()
        let responses = await withTaskGroup(of: GitReplicationResponse.self) { group in
            for _ in 0..<(GitReceiveBroker.maximumPending * 2) {
                group.addTask { await broker.handle(request, authenticatedPeer: f.peer) }
            }
            var responses: [GitReplicationResponse] = []
            for await response in group { responses.append(response) }
            return responses
        }
        #expect(responses.filter { if case .receiveReady = $0 { true } else { false } }.count == GitReceiveBroker.maximumPending)
        #expect(responses.filter { $0 == .error(.busy) }.count == GitReceiveBroker.maximumPending)
        await broker.close()
        let remaining = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("receive-") }
        #expect(remaining.isEmpty)
    }
}
