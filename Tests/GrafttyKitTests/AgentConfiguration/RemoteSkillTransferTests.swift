import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct RemoteSkillTransferTests {
    @Test("@spec REMOTE-28.11: When receiving remote skills, the application shall bind bounded chunks and their retained acknowledgements to the authenticated parent identity and registered repository, reject conflicting retries, and publish only a complete snapshot matching the declared runtime and revision.")
    func boundTransferAndLostAcknowledgementRetry() async throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/demo/SKILL.md", "demo")
        let snapshot = try fixture.capture()
        let bytes = try snapshot.encoded()
        let descriptor = RemoteSkillTransferDescriptor(operationID: UUID(), repositoryID: "/repo", runtime: "codex", revision: try snapshot.revision, byteCount: bytes.count)
        let receiver = RemoteSkillTransferReceiver(directory: fixture.root.appendingPathComponent("store"))
        let owner = try identity(1)
        let repos: Set<String> = ["/repo"]
        let initial = try await receiver.handle(.begin(descriptor), owner: owner, repositories: repos)
        #expect(initial.receivedBytes == 0)
        #expect(throws: RemoteSkillError.self) {
            try descriptor.validated(maximumBytes: 1)
        }
        let split = bytes.count / 2
        let chunk = bytes.prefix(split)
        let received = try await receiver.handle(.append(operationID: descriptor.operationID, offset: 0, bytes: Data(chunk)), owner: owner, repositories: repos)
        let retry = try await receiver.handle(.append(operationID: descriptor.operationID, offset: 0, bytes: Data(chunk)), owner: owner, repositories: repos)
        #expect(received == retry)
        await #expect(throws: RemoteSkillError.self) {
            try await receiver.handle(.append(operationID: descriptor.operationID, offset: 0, bytes: Data("conflict".utf8)), owner: owner, repositories: repos)
        }
        await #expect(throws: RemoteSkillError.self) {
            try await receiver.handle(.finish(operationID: descriptor.operationID), owner: identity(2), repositories: repos)
        }
        await #expect(throws: RemoteSkillError.self) {
            try await receiver.handle(.finish(operationID: descriptor.operationID), owner: owner, repositories: [])
        }
        await #expect(throws: RemoteSkillError.self) {
            try await receiver.handle(.finish(operationID: descriptor.operationID), owner: owner, repositories: repos)
        }
        _ = try await receiver.handle(.append(operationID: descriptor.operationID, offset: split, bytes: Data(bytes.dropFirst(split))), owner: owner, repositories: repos)
        let finished = try await receiver.handle(.finish(operationID: descriptor.operationID), owner: owner, repositories: repos)
        #expect(finished.phase == .staged)
        #expect(finished.receivedBytes == bytes.count)
        #expect(try await receiver.handle(.finish(operationID: descriptor.operationID), owner: owner, repositories: repos) == finished)
        #expect(try await receiver.handle(.begin(descriptor), owner: owner, repositories: repos) == finished)
    }

    @Test("@spec REMOTE-28.12: While receiving remote skill snapshots, the application shall bound active transfers, reserved bytes, chunk size, and retention time, and release incomplete content on cancellation or expiry without activating it.")
    func quotasExpiryAndAbort() async throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        let receiver = RemoteSkillTransferReceiver(directory: fixture.root.appendingPathComponent("store"), maximumActive: 1)
        let owner = try identity(1)
        let now = Date()
        let descriptor = RemoteSkillTransferDescriptor(operationID: UUID(), repositoryID: "/repo", runtime: "claude", revision: String(repeating: "0", count: 64), byteCount: 12)
        _ = try await receiver.handle(.begin(descriptor), owner: owner, repositories: ["/repo"], now: now)
        let another = RemoteSkillTransferDescriptor(operationID: UUID(), repositoryID: "/repo", runtime: "claude", revision: descriptor.revision, byteCount: 12)
        await #expect(throws: RemoteSkillError.self) { try await receiver.handle(.begin(another), owner: owner, repositories: ["/repo"], now: now) }
        await #expect(throws: RemoteSkillError.self) {
            try await receiver.handle(.append(operationID: descriptor.operationID, offset: 0, bytes: Data(repeating: 0, count: RemoteSkillTransferRequest.maximumChunkBytes + 1)), owner: owner, repositories: ["/repo"], now: now)
        }
        let aborted = try await receiver.handle(.abort(operationID: descriptor.operationID), owner: owner, repositories: ["/repo"], now: now)
        #expect(aborted.phase == .aborted)
        _ = try await receiver.handle(.begin(another), owner: owner, repositories: ["/repo"], now: now)
        await #expect(throws: RemoteSkillError.self) { try await receiver.handle(.finish(operationID: another.operationID), owner: owner, repositories: ["/repo"], now: now.addingTimeInterval(301)) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("store").path))
    }

    @Test func digestMismatchCannotPublishAndTransportFitsControlFrames() async throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        let snapshot = RemoteSkillSnapshot(runtime: .claude, files: [])
        let bytes = try snapshot.encoded()
        let descriptor = RemoteSkillTransferDescriptor(operationID: UUID(), repositoryID: "/repo", runtime: "claude", revision: String(repeating: "0", count: 64), byteCount: bytes.count)
        let receiver = RemoteSkillTransferReceiver(directory: fixture.root.appendingPathComponent("store"))
        let owner = try identity(1)
        _ = try await receiver.handle(.begin(descriptor), owner: owner, repositories: ["/repo"])
        _ = try await receiver.handle(.append(operationID: descriptor.operationID, offset: 0, bytes: bytes), owner: owner, repositories: ["/repo"])
        await #expect(throws: RemoteSkillError.self) { try await receiver.handle(.finish(operationID: descriptor.operationID), owner: owner, repositories: ["/repo"]) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("store").path))
        let request = RemoteSkillTransferRequest.append(operationID: UUID(), offset: 0, bytes: Data(repeating: 1, count: RemoteSkillTransferRequest.maximumChunkBytes))
        let encoded = try JSONEncoder().encode(request)
        #expect(encoded.count < 512 * 1024)
        #expect(try JSONDecoder().decode(RemoteSkillTransferRequest.self, from: encoded) == request)
    }

    @Test("@spec REMOTE-28.14: When sending remote skills, the application shall pin the destination identity, resume the same snapshot and operation from a matching retained offset, bound each request, and accept completion only from a matching staged acknowledgement.")
    func senderResumesAfterLostChunkAcknowledgement() async throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        let snapshot = RemoteSkillSnapshot(runtime: .codex, files: [.init(scope: .user, path: ".agents/skills/demo/SKILL.md", contents: Data(repeating: 97, count: 600_000))])
        let receiver = RemoteSkillTransferReceiver(directory: fixture.root.appendingPathComponent("store"))
        let owner = try identity(1)
        let operationID = UUID()
        let exchange = LostSkillReply(receiver: receiver, owner: owner)
        await #expect(throws: RemoteSkillError.self) {
            try await RemoteSkillTransferSender.transfer(snapshot, repositoryID: "/repo", operationID: operationID) { request in
                try await exchange.send(request)
            }
        }
        let result = try await RemoteSkillTransferSender.transfer(snapshot, repositoryID: "/repo", operationID: operationID) { request in
            try await exchange.send(request)
        }
        #expect(result.phase == .staged)
        #expect(await exchange.firstOffsetAfterResume == RemoteSkillTransferRequest.maximumChunkBytes)
        #expect(result.descriptor.revision == (try snapshot.revision))
        await #expect(throws: RemoteSkillError.self) {
            try await RemoteSkillTransferSender.transfer(snapshot, repositoryID: "/repo", operationID: UUID()) { _ in result }
        }
    }

    private func identity(_ byte: UInt8) throws -> RemoteMacConnectionSummary.ID {
        .init(deviceID: .init(value: "parent"), fingerprint: try .init(rawBytes: Data(repeating: byte, count: 32)))
    }
}

private actor LostSkillReply {
    let receiver: RemoteSkillTransferReceiver
    let owner: RemoteMacConnectionSummary.ID
    var dropped = false
    var firstOffsetAfterResume: Int?
    init(receiver: RemoteSkillTransferReceiver, owner: RemoteMacConnectionSummary.ID) { self.receiver = receiver; self.owner = owner }
    func send(_ request: RemoteSkillTransferRequest) async throws -> RemoteSkillTransferStatus {
        #expect(try JSONEncoder().encode(request).count < 512 * 1024)
        let result = try await receiver.handle(request, owner: owner, repositories: ["/repo"])
        if case .append(_, let offset, _) = request {
            if !dropped { dropped = true; throw RemoteSkillError("fixture lost reply") }
            if firstOffsetAfterResume == nil { firstOffsetAfterResume = offset }
        }
        return result
    }
}
