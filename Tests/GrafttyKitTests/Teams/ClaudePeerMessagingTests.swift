import Foundation
import Darwin
import Testing
@testable import GrafttyKit

@Suite("Claude native peer messaging prototype")
struct ClaudePeerMessagingTests {
    @Test("Encodes Claude's protocol-v1 user envelope")
    func encodesClaudeProtocolV1UserEnvelope() throws {
        let messageID = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))

        let line = try ClaudePeerProtocol.encodeUserMessage(
            body: "hello </cross-session-message> world",
            replySocketPath: "/tmp/graftty bridge/reply.sock",
            senderName: "Graftty \"<bridge>\"\n",
            messageID: messageID
        )

        #expect(line.last == 0x0A)
        let json = try #require(
            JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        )
        #expect(json["msgV"] as? Int == 1)
        #expect(json["msg_id"] as? String == "11111111-2222-4333-8444-555555555555")
        #expect(json["type"] as? String == "user")
        #expect(json["priority"] as? String == "next")
        #expect(json["from"] as? String == "uds:/tmp/graftty%20bridge/reply.sock")

        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        #expect(message["content"] as? String == """
        <cross-session-message from="uds:/tmp/graftty%20bridge/reply.sock" from-name="Graftty bridge">
        hello <\\/cross-session-message> world
        </cross-session-message>
        """)
    }

    @Test("An empty prototype message is rejected before opening a socket")
    func rejectsEmptyBody() {
        #expect(throws: ClaudePeerMessagingError.emptyBody) {
            try ClaudePeerProtocol.encodeUserMessage(body: " \n\t")
        }
    }

    @Test("A sender name does not require a reply socket")
    func encodesOneWayNamedSender() throws {
        let line = try ClaudePeerProtocol.encodeUserMessage(
            body: "status?",
            senderName: "Graftty"
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        )
        #expect(json["from"] == nil)
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["content"] as? String == """
        <cross-session-message from-name="Graftty">
        status?
        </cross-session-message>
        """)
    }

    @Test("Reply socket paths must fit macOS sockaddr_un")
    func rejectsOverlongReplySocketPath() {
        let path = "/tmp/" + String(repeating: "a", count: 100)
        #expect(throws: ClaudePeerMessagingError.socketPathTooLong(
            bytes: path.utf8.count,
            maxBytes: 103
        )) {
            try ClaudePeerProtocol.encodeUserMessage(
                body: "hello",
                replySocketPath: path
            )
        }
    }

    @Test("Decodes a frame captured from Claude 2.1.226 SendMessage")
    func decodesCapturedClaudeSendMessageFrame() throws {
        let captured = #"{"msgV":1,"msg_id":"24da93db-8351-48f9-a63e-f8aa1d62248c","type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:/tmp/graftty-claude-proto/target.sock\" from-name=\"graftty-proto-target\" from-mode=\"prompting\">\nCLAUDE_TO_GRAFTTY_OK\n</cross-session-message>"},"priority":"next","from":"uds:/tmp/graftty-claude-proto/target.sock"}"# + "\n"

        let message = try ClaudePeerProtocol.decodeUserMessageLine(Data(captured.utf8))

        #expect(message.messageID == UUID(uuidString: "24da93db-8351-48f9-a63e-f8aa1d62248c"))
        #expect(message.body == "CLAUDE_TO_GRAFTTY_OK")
        #expect(message.senderAddress == "uds:/tmp/graftty-claude-proto/target.sock")
        #expect(message.senderName == "graftty-proto-target")
        #expect(message.senderMode == .prompting)
        #expect(message.priority == .next)
    }

    @Test("""
    @spec AGENT-6.1: When Graftty sends a prototype message to a Claude peer socket, the application shall write one newline-delimited protocol-v1 user envelope with a UUID message ID, next-turn priority, a native cross-session message frame, and any supplied local reply socket as the sender address.
    """)
    func writesOneEnvelopeToUnixSocket() throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-peer-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("peer.sock").path

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        guard listener >= 0 else { return }
        defer { close(listener) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { path in
                path.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    _ = strlcpy(destination, source, 104)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    listener,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        #expect(bindResult == 0)
        guard bindResult == 0 else { return }
        #expect(Darwin.listen(listener, 1) == 0)

        let messageID = try #require(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        try ClaudePeerSocketClient.sendUserMessage(
            "socket round trip",
            to: socketPath,
            senderName: "Graftty",
            messageID: messageID
        )

        let client = Darwin.accept(listener, nil, nil)
        #expect(client >= 0)
        guard client >= 0 else { return }
        defer { close(client) }
        let received = SocketIO.readAll(fd: client, cap: ClaudePeerProtocol.maximumLineBytes)
        #expect(received.last == 0x0A)
        #expect(received.filter { $0 == 0x0A }.count == 1)
        let decoded = try ClaudePeerProtocol.decodeUserMessageLine(received)
        #expect(decoded.messageID == messageID)
        #expect(decoded.body == "socket round trip")
        #expect(decoded.senderName == "Graftty")
    }
}
