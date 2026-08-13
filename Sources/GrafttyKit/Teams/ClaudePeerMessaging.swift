import Darwin
import Foundation

/// Errors surfaced by the experimental Claude peer-socket transport.
public enum ClaudePeerMessagingError: Error, Equatable, Sendable {
    case emptyBody
    case invalidEnvelope
    case unsupportedProtocolVersion(Int)
    case unsupportedMessageType(String)
    case invalidSocketPath(String)
    case socketPathTooLong(bytes: Int, maxBytes: Int)
    case messageTooLarge(bytes: Int, maxBytes: Int)
    case socketCreationFailed
    case connectFailed(path: String, errno: Int32)
    case writeFailed(errno: Int32)
}

public enum ClaudePeerPriority: String, Codable, Equatable, Sendable {
    case now
    case next
    case later
}

public enum ClaudePeerPermissionMode: String, Codable, Equatable, Sendable {
    case bypass
    case prompting
}

/// Normalized message received from Claude's native `SendMessage` transport.
public struct ClaudePeerInboundMessage: Equatable, Sendable {
    public let messageID: UUID?
    public let body: String
    public let senderAddress: String?
    public let senderName: String?
    public let senderMode: ClaudePeerPermissionMode?
    public let priority: ClaudePeerPriority

    public init(
        messageID: UUID?,
        body: String,
        senderAddress: String?,
        senderName: String?,
        senderMode: ClaudePeerPermissionMode?,
        priority: ClaudePeerPriority
    ) {
        self.messageID = messageID
        self.body = body
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.senderMode = senderMode
        self.priority = priority
    }
}

/// Encoder for Claude Code's local cross-session messaging protocol.
///
/// This is intentionally a narrow compatibility prototype. Claude Code
/// 2.1.226 accepts one JSON object per line on its mode-0600 Unix socket. The
/// peer protocol is not a documented compatibility contract, so callers must
/// continue to treat a successful write as transport acceptance rather than a
/// durable-delivery acknowledgement.
public enum ClaudePeerProtocol {
    public static let version = 1
    public static let maximumLineBytes = 1 * 1024 * 1024

    private static let envelopeTag = "cross-session-message"

    /// Builds the protocol-v1 user envelope Claude's native `SendMessage`
    /// implementation writes to another local session.
    public static func encodeUserMessage(
        body: String,
        replySocketPath: String? = nil,
        senderName: String? = nil,
        messageID: UUID = UUID()
    ) throws -> Data {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudePeerMessagingError.emptyBody
        }

        let senderAddress: String?
        if let replySocketPath {
            try validateSocketPath(replySocketPath)
            senderAddress = "uds:" + percentEncodeAddress(replySocketPath)
        } else {
            senderAddress = nil
        }

        let content = crossSessionFrame(
            body: body,
            senderAddress: senderAddress,
            senderName: senderName
        )
        let envelope = UserEnvelope(
            msgV: version,
            msgID: messageID.uuidString.lowercased(),
            type: "user",
            message: .init(role: "user", content: content),
            priority: "next",
            from: senderAddress
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(envelope)
        line.append(0x0A)
        guard line.count <= maximumLineBytes else {
            throw ClaudePeerMessagingError.messageTooLarge(
                bytes: line.count,
                maxBytes: maximumLineBytes
            )
        }
        return line
    }

    /// Decodes a single newline-delimited frame emitted by Claude's native
    /// `SendMessage`. The outer sender address is authoritative for replies;
    /// the XML-like frame contributes display and permission-mode metadata.
    public static func decodeUserMessageLine(_ line: Data) throws -> ClaudePeerInboundMessage {
        let envelope: ReceivedEnvelope
        do {
            envelope = try JSONDecoder().decode(ReceivedEnvelope.self, from: line)
        } catch {
            throw ClaudePeerMessagingError.invalidEnvelope
        }
        guard envelope.msgV == version else {
            throw ClaudePeerMessagingError.unsupportedProtocolVersion(envelope.msgV)
        }
        guard envelope.type == "user", envelope.message.role == "user" else {
            throw ClaudePeerMessagingError.unsupportedMessageType(envelope.type)
        }

        let frame = parseCrossSessionFrame(envelope.message.content)
        return ClaudePeerInboundMessage(
            messageID: envelope.msgID.flatMap(UUID.init(uuidString:)),
            body: frame?.body ?? envelope.message.content,
            senderAddress: envelope.from ?? frame?.attributes["from"],
            senderName: frame?.attributes["from-name"],
            senderMode: frame?.attributes["from-mode"].flatMap(ClaudePeerPermissionMode.init(rawValue:)),
            priority: ClaudePeerPriority(rawValue: envelope.priority ?? "next") ?? .next
        )
    }

    public static func validateSocketPath(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw ClaudePeerMessagingError.invalidSocketPath(path)
        }
        let bytes = path.utf8.count
        guard bytes <= SocketServer.maxPathBytes else {
            throw ClaudePeerMessagingError.socketPathTooLong(
                bytes: bytes,
                maxBytes: SocketServer.maxPathBytes
            )
        }
    }

    private static func crossSessionFrame(
        body: String,
        senderAddress: String?,
        senderName: String?
    ) -> String {
        var attributes: [String] = []
        if let senderAddress {
            attributes.append(#"from="\#(senderAddress)""#)
        }
        if let senderName,
           let sanitizedSenderName = sanitizeSenderName(senderName),
           !sanitizedSenderName.isEmpty
        {
            attributes.append(#"from-name="\#(sanitizedSenderName)""#)
        }
        let suffix = attributes.isEmpty ? "" : " " + attributes.joined(separator: " ")
        let scrubbedBody = scrubClosingEnvelopeTag(in: body)
        return "<\(envelopeTag)\(suffix)>\n\(scrubbedBody)\n</\(envelopeTag)>"
    }

    private static func parseCrossSessionFrame(
        _ content: String
    ) -> (body: String, attributes: [String: String])? {
        let prefix = "<\(envelopeTag)"
        let suffix = "\n</\(envelopeTag)>"
        guard content.hasPrefix(prefix), content.hasSuffix(suffix),
              let headerEnd = content.range(of: ">\n")
        else {
            return nil
        }

        let attributeStart = content.index(content.startIndex, offsetBy: prefix.count)
        let attributeText = String(content[attributeStart..<headerEnd.lowerBound])
        guard attributeText.isEmpty || attributeText.hasPrefix(" ") else { return nil }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = content.index(content.endIndex, offsetBy: -suffix.count)
        guard bodyStart <= bodyEnd else { return nil }

        let pattern = #"([a-z-]+)="([^"<>\n\r]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let searchRange = NSRange(attributeText.startIndex..<attributeText.endIndex, in: attributeText)
        var attributes: [String: String] = [:]
        for match in regex.matches(in: attributeText, range: searchRange) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: attributeText),
                  let valueRange = Range(match.range(at: 2), in: attributeText)
            else {
                continue
            }
            attributes[String(attributeText[keyRange])] = String(attributeText[valueRange])
        }
        return (String(content[bodyStart..<bodyEnd]), attributes)
    }

    private static func scrubClosingEnvelopeTag(in body: String) -> String {
        let pattern = #"</(?=cross-session-message(?:[>\s/]|$))"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return body
        }
        let fullRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = regex.matches(in: body, range: fullRange)
        var scrubbed = body
        for match in matches.reversed() {
            guard let range = Range(match.range, in: scrubbed) else { continue }
            scrubbed.replaceSubrange(range, with: #"<\/"#)
        }
        return scrubbed
    }

    private static func sanitizeSenderName(_ value: String) -> String? {
        let withoutMarkup = value.replacingOccurrences(
            of: #"["<>]"#,
            with: "",
            options: .regularExpression
        )
        let visibleScalars = withoutMarkup.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }
        let cleaned = String(String.UnicodeScalarView(visibleScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let characters = Array(cleaned)
        guard characters.count > 64 else { return cleaned }
        return String(characters.prefix(64)) + "…"
    }

    private static func percentEncodeAddress(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isAddressByte(byte) {
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    private static func isAddressByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122,
             0x3A, 0x5F, 0x2F, 0x2E, 0x5C, 0x2D:
            return true
        default:
            return false
        }
    }

    private struct UserEnvelope: Encodable {
        struct UserMessage: Encodable {
            let role: String
            let content: String
        }

        let msgV: Int
        let msgID: String
        let type: String
        let message: UserMessage
        let priority: String
        let from: String?

        enum CodingKeys: String, CodingKey {
            case msgV
            case msgID = "msg_id"
            case type
            case message
            case priority
            case from
        }
    }

    private struct ReceivedEnvelope: Decodable {
        struct UserMessage: Decodable {
            let role: String
            let content: String
        }

        let msgV: Int
        let msgID: String?
        let type: String
        let message: UserMessage
        let priority: String?
        let from: String?

        enum CodingKeys: String, CodingKey {
            case msgV
            case msgID = "msg_id"
            case type
            case message
            case priority
            case from
        }
    }
}

/// One-shot transport for the prototype protocol encoder.
public enum ClaudePeerSocketClient {
    /// Writes one message to a live Claude session and closes the connection.
    /// The returned ID identifies a future native delivery-status receipt if a
    /// `replySocketPath` listener is supplied by the caller.
    @discardableResult
    public static func sendUserMessage(
        _ body: String,
        to targetSocketPath: String,
        replySocketPath: String? = nil,
        senderName: String? = nil,
        messageID: UUID = UUID(),
        timeoutSeconds: Int = 5
    ) throws -> UUID {
        try ClaudePeerProtocol.validateSocketPath(targetSocketPath)
        let line = try ClaudePeerProtocol.encodeUserMessage(
            body: body,
            replySocketPath: replySocketPath,
            senderName: senderName,
            messageID: messageID
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClaudePeerMessagingError.socketCreationFailed
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        targetSocketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { path in
                path.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    _ = strlcpy(destination, source, 104)
                }
            }
        }
        // SO_SNDTIMEO does not bound connect(2); a wedged peer whose socket
        // inode still exists would otherwise pin this thread (and the
        // delivery actor's in-flight key) indefinitely. Connect
        // non-blocking, poll with the caller's timeout, then restore
        // blocking mode so SO_SNDTIMEO governs the write.
        let originalFlags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    fd,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                throw ClaudePeerMessagingError.connectFailed(
                    path: targetSocketPath,
                    errno: errno
                )
            }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(timeoutSeconds * 1000))
            guard ready == 1 else {
                throw ClaudePeerMessagingError.connectFailed(
                    path: targetSocketPath,
                    errno: ready == 0 ? ETIMEDOUT : errno
                )
            }
            var socketError: Int32 = 0
            var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorSize)
            guard socketError == 0 else {
                throw ClaudePeerMessagingError.connectFailed(
                    path: targetSocketPath,
                    errno: socketError
                )
            }
        }
        _ = fcntl(fd, F_SETFL, originalFlags)

        do {
            let bytes = [UInt8](line)
            try bytes.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                try SocketIO.writeAll(
                    fd: fd,
                    bytes: baseAddress,
                    count: buffer.count
                )
            }
        } catch let error as SocketIO.WriteError {
            switch error {
            case .writeFailed(let errorNumber):
                throw ClaudePeerMessagingError.writeFailed(errno: errorNumber)
            }
        }
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))
        return messageID
    }
}

public protocol ClaudePeerClienting: Sendable {
    func send(
        body: String,
        socketPath: String,
        replySocketPath: String?,
        senderName: String?
    ) async throws -> UUID
}

public struct ClaudePeerClient: ClaudePeerClienting, Sendable {
    public init() {}

    public func send(
        body: String,
        socketPath: String,
        replySocketPath: String?,
        senderName: String?
    ) async throws -> UUID {
        // The socket client blocks on connect/poll/write (up to ~10s); run it
        // on a global dispatch queue so it never occupies a thread of the
        // cooperative pool. Not OffMainIO: that is a single serial queue and
        // would serialize deliveries across worktrees.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try ClaudePeerSocketClient.sendUserMessage(
                        body,
                        to: socketPath,
                        replySocketPath: replySocketPath,
                        senderName: senderName
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
