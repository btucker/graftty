import Darwin
import Foundation
import Testing
@testable import GrafttyKit

@Suite("Claude native reply bridge")
struct ClaudePeerReplyBridgeTests {
    @Test("@spec TEAM-14.35: When a Claude agent replies through its Graftty reply socket, the application shall forward the reply using the socket's original message and exact recipient identity, preserving the sender device even when worktree names match.")
    func forwardsWithBoundIdentityAcrossSameNamedDevices() async throws {
        let recorder = Recorder()
        let bridge = ClaudePeerReplyBridge { message, recipient, reply in
            await recorder.record(message, recipient, reply)
            return .ok
        }
        let first = message(device: "MAC-A")
        let second = message(device: "MAC-B")
        let recipient = recipient()
        let firstPath = try #require(try await bridge.replySocketPath(message: first, recipient: recipient))
        let secondPath = try #require(try await bridge.replySocketPath(message: second, recipient: recipient))
        #expect(firstPath != secondPath)
        #expect(firstPath.utf8.count <= SocketServer.maxPathBytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: firstPath)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: (firstPath as NSString).deletingLastPathComponent)
        #expect((directoryPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        try ClaudePeerSocketClient.sendUserMessage("reply A", to: firstPath, replySocketPath: peerSocket, senderName: "wrong display name")
        try ClaudePeerSocketClient.sendUserMessage("reply B", to: secondPath, replySocketPath: peerSocket, senderName: "wrong display name")
        try await waitForCount(2, recorder: recorder)
        let calls = await recorder.calls
        #expect(calls.first(where: { $0.2.body == "reply A" })?.0 == first)
        #expect(calls.first(where: { $0.2.body == "reply B" })?.0 == second)
        #expect(calls.allSatisfy { $0.1 == recipient })
        await bridge.close()
        #expect(!FileManager.default.fileExists(atPath: firstPath))
        #expect(!FileManager.default.fileExists(atPath: secondPath))
    }

    @Test("@spec TEAM-14.36: If a native reply lacks the bound Claude socket sender address or a valid message ID, or repeats an accepted message ID, then the application shall not forward it, and native receipt envelopes shall not become replies.")
    func validatesSenderAndDeduplicatesNativeIDs() async throws {
        let recorder = Recorder()
        let bridge = ClaudePeerReplyBridge { message, recipient, reply in
            await recorder.record(message, recipient, reply)
            return .ok
        }
        let path = try #require(try await bridge.replySocketPath(message: message(), recipient: recipient()))
        // Shape recorded from Claude 2.1.226 in the native-peer prototype notes.
        await bridge.receive(Data(#"{"msgV":1,"type":"control","action":"peer_message_status","orig_msg_id":"24da93db-8351-48f9-a63e-f8aa1d62248c","status":"delivered"}"#.utf8), socketPath: path)
        await bridge.receive(try ClaudePeerProtocol.encodeUserMessage(body: "spoofed", replySocketPath: "/tmp/someone-else.sock", senderName: "expected name"), socketPath: path)
        await bridge.receive(try ClaudePeerProtocol.encodeUserMessage(body: "missing sender"), socketPath: path)
        let id = UUID()
        let line = try ClaudePeerProtocol.encodeUserMessage(body: "real reply", replySocketPath: peerSocket, messageID: id)
        var invalid = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        invalid["msg_id"] = "invalid"
        await bridge.receive(try JSONSerialization.data(withJSONObject: invalid), socketPath: path)
        await bridge.receive(line, socketPath: path)
        await bridge.receive(line, socketPath: path)
        #expect(await recorder.calls.count == 1)
        #expect(await recorder.calls.first?.2.messageID == id)
        await bridge.close()
    }

    @Test("@spec TEAM-14.37: If native reply forwarding fails, then the application shall notify the bound Claude recipient through its native socket with an explicit message-ID retry command and no reply socket.")
    func forwardingFailureNotifiesRecipientWithoutReplyLoop() async throws {
        let client = FailureRecorder()
        let original = message()
        let bridge = ClaudePeerReplyBridge(client: client) { _, _, _ in .error("Mac offline") }
        let path = try #require(try await bridge.replySocketPath(message: original, recipient: recipient()))
        await bridge.receive(try ClaudePeerProtocol.encodeUserMessage(body: "reply", replySocketPath: peerSocket), socketPath: path)
        let calls = await client.calls
        #expect(calls.count == 1)
        #expect(calls.first?.socketPath == peerSocket)
        #expect(calls.first?.replySocketPath == nil)
        #expect(calls.first?.body.contains("Mac offline") == true)
        #expect(calls.first?.body.contains("graftty team reply") == true)
        #expect(calls.first?.body.contains(original.id) == true)
        await bridge.close()
    }

    @Test("@spec TEAM-14.38: While native reply sockets are available, the application shall bound their count and accepted frame size, omit system-message reply sockets, reuse an existing message binding, and reject new bindings after close.")
    func boundsBindingsAndClosesPermanently() async throws {
        let recorder = Recorder()
        let bridge = ClaudePeerReplyBridge(maximumBindings: 1) { message, recipient, reply in
            await recorder.record(message, recipient, reply)
            return .ok
        }
        let original = message()
        let path = try #require(try await bridge.replySocketPath(message: original, recipient: recipient()))
        #expect(try await bridge.replySocketPath(message: original, recipient: recipient()) == path)
        await #expect(throws: ClaudePeerReplyBridgeError.capacityReached) {
            try await bridge.replySocketPath(message: message(device: "ANOTHER-MAC"), recipient: recipient())
        }
        let system = message(system: true)
        #expect(try await bridge.replySocketPath(message: system, recipient: recipient()) == nil)
        await bridge.receive(Data(repeating: 0x61, count: ClaudePeerProtocol.maximumLineBytes + 1), socketPath: path)
        #expect(await recorder.calls.isEmpty)
        await bridge.close()
        await bridge.close()
        await #expect(throws: ClaudePeerReplyBridgeError.closed) {
            try await bridge.replySocketPath(message: original, recipient: recipient())
        }
    }

    @Test("A native socket cannot bind a message addressed to a different exact agent or runtime")
    func refusesMismatchedRecipient() async throws {
        let bridge = ClaudePeerReplyBridge { _, _, _ in .ok }
        for target in [
            TeamInboxEndpoint(member: "worker", worktree: "/repo/worker", runtime: "codex"),
            TeamInboxEndpoint(member: "worker", worktree: "/repo/worker", runtime: "claude", agentID: "claude-ffffffffffff"),
        ] {
            let original = message()
            let wrongTarget = TeamInboxMessage(id: original.id, batchID: nil, createdAt: original.createdAt, team: original.team, repoPath: original.repoPath, from: original.from, to: target, priority: .normal, body: original.body)
            await #expect(throws: ClaudePeerReplyBridgeError.invalidRecipient) {
                try await bridge.replySocketPath(message: wrongTarget, recipient: recipient())
            }
        }
        await bridge.close()
    }

    @Test("Unterminated native clients eventually close, and bridge shutdown closes pending clients")
    func boundsReadDeadlineAndWakesReadersOnClose() async throws {
        let recorder = Recorder()
        let bridge = ClaudePeerReplyBridge { message, recipient, reply in
            await recorder.record(message, recipient, reply)
            return .ok
        }
        let path = try #require(try await bridge.replySocketPath(message: message(), recipient: recipient()))
        let fd = try connectSocket(path)
        defer { Darwin.close(fd) }
        // The peer keeps its write side open without a complete JSON line.
        var byte: UInt8 = 0x7B
        #expect(Darwin.write(fd, &byte, 1) == 1)
        #expect(await socketCloses(fd))
        #expect(await recorder.calls.isEmpty)

        let secondFD = try connectSocket(path)
        defer { Darwin.close(secondFD) }
        await bridge.close()
        #expect(await socketCloses(secondFD))
        #expect(await recorder.calls.isEmpty)
    }

    private let peerSocket = "/tmp/claude bound peer.sock"

    private func socketCloses(_ fd: Int32) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // The production two-second deadline starts when its worker
                // runs. Allow accept/worker scheduling under the parallel full
                // suite, and keep this blocking poll off the cooperative pool.
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 15_000)
                guard ready > 0 else {
                    continuation.resume(returning: false)
                    return
                }
                var byte: UInt8 = 0
                let count = Darwin.recv(fd, &byte, 1, MSG_DONTWAIT)
                continuation.resume(returning: count == 0 || (count < 0 && errno == ECONNRESET))
            }
        }
    }

    private func message(device: String = "MAC-A", system: Bool = false) -> TeamInboxMessage {
        TeamInboxMessage(id: UUID().uuidString, batchID: nil, createdAt: Date(), team: "test", repoPath: "/repo", from: system ? .system(repoPath: "/repo") : .init(member: "same-name", worktree: "graftty-mac://\(device)/repo/same-name", runtime: "codex", agentID: "codex-123456789abc"), to: .init(member: "worker", worktree: "/repo/worker", runtime: "claude"), priority: .normal, body: "status?")
    }

    private func recipient() -> TeamAgentDescriptor {
        TeamAgentDescriptor(id: TeamAgentIdentity(runtime: .claude, nativeSessionID: "recipient"), teamID: TeamLookup.id(forRepoPath: "/repo"), worktreePath: "/repo/worker", runtime: .claude, identitySource: "recipient", displayName: "same-name", paneSessionName: nil, registeredAt: Date(timeIntervalSince1970: 0), isReachable: true, transport: .claude(socketPath: peerSocket, protocolVersion: 1))
    }

    private func connectSocket(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClaudePeerReplyBridgeError.socketSetupFailed(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, source, 104) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            Darwin.close(fd)
            throw ClaudePeerReplyBridgeError.socketSetupFailed(error)
        }
        return fd
    }

    private func waitForCount(_ count: Int, recorder: Recorder) async throws {
        for _ in 0..<100 {
            if await recorder.calls.count == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await recorder.calls.count == count)
    }

    private actor Recorder {
        var calls: [(TeamInboxMessage, TeamAgentDescriptor, ClaudePeerInboundMessage)] = []
        func record(_ message: TeamInboxMessage, _ recipient: TeamAgentDescriptor, _ reply: ClaudePeerInboundMessage) {
            calls.append((message, recipient, reply))
        }
    }

    private actor FailureRecorder: ClaudePeerClienting {
        struct Call {
            let body: String
            let socketPath: String
            let replySocketPath: String?
        }
        var calls: [Call] = []
        func send(body: String, socketPath: String, replySocketPath: String?, senderName: String?) async throws -> UUID {
            calls.append(.init(body: body, socketPath: socketPath, replySocketPath: replySocketPath))
            return UUID()
        }
    }
}
