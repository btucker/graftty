import Darwin
import Foundation

public enum ClaudePeerReplyBridgeError: Error, Equatable {
    case closed
    case capacityReached
    case invalidRecipient
    case directoryCreationFailed(Int32)
    case socketSetupFailed(Int32)
}

/// Gives a native Claude reply address an immutable Graftty destination.
/// Native display names never select the recipient. The injected handler must
/// bound its forwarding operation and return `.ok` only after accepting it.
/// A socket write remains transport acceptance, not proof of remote delivery.
/// Failure notifications are best effort; the handler should log its outcome.
/// This accepts the repository's captured protocol-v1 user frame. It does not
/// issue Claude delivery-status receipts or attest a Claude permission mode.
public actor ClaudePeerReplyBridge {
    public typealias Handler = @Sendable (
        TeamInboxMessage, TeamAgentDescriptor, ClaudePeerInboundMessage
    ) async -> ResponseMessage

    private struct BindingKey: Hashable {
        let messageID: String
        let team: String
        let origin: TeamInboxEndpoint
        let recipientID: TeamAgentIdentity
        let recipientWorktree: String
        let recipientSocket: String
    }

    private struct Binding {
        let message: TeamInboxMessage
        let recipient: TeamAgentDescriptor
        let listener: NativeReplyListener
        var lastUsed: Date
        var receivedIDs: Set<UUID> = []
    }

    private let directoryParent: URL
    private let maximumBindings: Int
    private let client: any ClaudePeerClienting
    private let handler: Handler
    // Admission spans socket reads and forwarding, so a stalled handler cannot
    // create an unbounded number of detached tasks or socket workers.
    private let admission = DispatchSemaphore(value: 16)
    private var directory: URL?
    private var bindings: [BindingKey: Binding] = [:]
    private var paths: [String: BindingKey] = [:]
    private var isClosed = false

    public init(
        directoryParent: URL = URL(fileURLWithPath: "/tmp"),
        maximumBindings: Int = 256,
        client: any ClaudePeerClienting = ClaudePeerClient(),
        handler: @escaping Handler
    ) {
        self.directoryParent = directoryParent
        self.maximumBindings = max(1, maximumBindings)
        self.client = client
        self.handler = handler
    }

    deinit {
        for binding in bindings.values { binding.listener.stop() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    public func replySocketPath(
        message: TeamInboxMessage,
        recipient: TeamAgentDescriptor
    ) throws -> String? {
        guard !isClosed else { throw ClaudePeerReplyBridgeError.closed }
        guard !message.from.isSystem else { return nil }
        guard recipient.runtime == .claude,
              recipient.teamID == TeamLookup.id(forRepoPath: message.repoPath),
              recipient.worktreePath == message.to.worktree,
              message.to.agentID == nil || message.to.agentID == recipient.id.rawValue,
              message.to.runtime == nil || message.to.runtime == recipient.runtime.rawValue,
              case .claude(let peerSocket, let version) = recipient.transport,
              version == ClaudePeerProtocol.version,
              !peerSocket.utf8.contains(0) else {
            throw ClaudePeerReplyBridgeError.invalidRecipient
        }
        try ClaudePeerProtocol.validateSocketPath(peerSocket)
        let key = BindingKey(
            messageID: message.id,
            team: message.team,
            origin: message.from,
            recipientID: recipient.id,
            recipientWorktree: recipient.worktreePath,
            recipientSocket: peerSocket
        )
        if var existing = bindings[key] {
            existing.lastUsed = Date()
            bindings[key] = existing
            return existing.listener.socketPath
        }
        expireIdleBindings()
        guard bindings.count < maximumBindings else {
            throw ClaudePeerReplyBridgeError.capacityReached
        }
        let root = try privateDirectory()
        let path = root.appendingPathComponent(UUID().uuidString.prefix(12) + ".sock").path
        let listener = try NativeReplyListener(socketPath: path, admission: admission) { [weak self] line in
            await self?.receive(line, socketPath: path)
        }
        bindings[key] = Binding(message: message, recipient: recipient, listener: listener, lastUsed: Date())
        paths[path] = key
        return path
    }

    /// Stops new replies immediately. Forwarding already handed to the handler
    /// may finish, since cancelling it cannot retract a remote accepted send.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        for binding in bindings.values { binding.listener.stop() }
        bindings.removeAll()
        paths.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // Internal to allow deterministic protocol-validation tests. Socket callers
    // also pass the listener's same-owner UID check before reaching this method.
    func receive(_ line: Data, socketPath: String) async {
        guard !isClosed,
              line.count <= ClaudePeerProtocol.maximumLineBytes,
              let key = paths[socketPath],
              var binding = bindings[key],
              let reply = try? ClaudePeerProtocol.decodeUserMessageLine(line),
              let id = reply.messageID,
              let address = reply.senderAddress,
              address.hasPrefix("uds:"),
              String(address.dropFirst(4)).removingPercentEncoding == key.recipientSocket,
              !reply.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !binding.receivedIDs.contains(id) else { return }

        // Receipts and future control envelopes fail the user-envelope decoder.
        // Keep IDs after errors too: a timeout might follow a remote acceptance,
        // so retransmission must be an explicit user/agent decision.
        guard binding.receivedIDs.count < 256 else {
            await notifyFailure("This native reply address has reached its reply limit.", binding: binding)
            return
        }
        binding.receivedIDs.insert(id)
        binding.lastUsed = Date()
        bindings[key] = binding
        let response = await handler(binding.message, binding.recipient, reply)
        guard !isClosed, response != .ok else { return }
        let detail: String
        switch response {
        case .error(let error): detail = String(error.prefix(2048))
        case .serverBusy: detail = "The Graftty control socket is busy."
        default: detail = "Graftty returned an unexpected forwarding response."
        }
        await notifyFailure(detail, binding: binding)
    }

    private func notifyFailure(_ detail: String, binding: Binding) async {
        guard !isClosed,
              case .claude(let socketPath, _) = binding.recipient.transport else { return }
        let command = TeamReplyResolver.command(messageID: binding.message.id)
        // No sender socket means Claude cannot accidentally reply to this error
        // and recursively create more failed forwarding notifications.
        _ = try? await client.send(
            body: "Graftty could not confirm forwarding your native reply. \(detail)\nCheck delivery before retrying. To retry explicitly, use \(command) with your message body.",
            socketPath: socketPath,
            replySocketPath: nil,
            senderName: "Graftty reply status"
        )
    }

    private func expireIdleBindings() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for key in bindings.keys.filter({ bindings[$0]!.lastUsed < cutoff }) {
            guard let binding = bindings.removeValue(forKey: key) else { continue }
            paths.removeValue(forKey: binding.listener.socketPath)
            binding.listener.stop()
        }
    }

    private func privateDirectory() throws -> URL {
        if let directory { return directory }
        var template = Array(directoryParent.appendingPathComponent("graftty-reply-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else {
            throw ClaudePeerReplyBridgeError.directoryCreationFailed(errno)
        }
        let created = URL(fileURLWithPath: String(cString: template))
        directory = created
        return created
    }
}

/// Descriptor lifetime is protected by the lock. The source owns the listener;
/// each bounded worker owns its accepted descriptor until `finish` closes it.
private final class NativeReplyListener: @unchecked Sendable {
    let socketPath: String
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.graftty.claude-replies.accept", qos: .utility)
    private let admission: DispatchSemaphore
    private let onLine: @Sendable (Data) async -> Void
    private var source: DispatchSourceRead?
    private var clients: Set<Int32> = []
    private var stopped = false

    init(socketPath: String, admission: DispatchSemaphore, onLine: @escaping @Sendable (Data) async -> Void) throws {
        self.socketPath = socketPath
        self.admission = admission
        self.onLine = onLine
        try ClaudePeerProtocol.validateSocketPath(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClaudePeerReplyBridgeError.socketSetupFailed(errno) }
        var sourceOwnsFD = false
        var bound = false
        defer {
            if !sourceOwnsFD {
                Darwin.close(fd)
                if bound { unlink(socketPath) }
            }
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ClaudePeerReplyBridgeError.socketSetupFailed(errno) }
        bound = true
        guard chmod(socketPath, 0o600) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              Darwin.listen(fd, 16) == 0 else {
            throw ClaudePeerReplyBridgeError.socketSetupFailed(errno)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        sourceOwnsFD = true
        source.resume()
    }

    deinit { stop() }

    func stop() {
        let source = lock.withLock { () -> DispatchSourceRead? in
            guard !stopped else { return nil }
            stopped = true
            for fd in clients { _ = Darwin.shutdown(fd, SHUT_RDWR) }
            unlink(socketPath)
            let source = self.source
            self.source = nil
            return source
        }
        source?.cancel()
    }

    private func accept(_ listener: Int32) {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              admission.wait(timeout: .now()) == .success else {
            Darwin.close(fd)
            return
        }
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            clients.insert(fd)
            return true
        }
        guard accepted else {
            Darwin.close(fd)
            admission.signal()
            return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let line = Self.readLine(fd: fd)
            let active = lock.withLock { () -> Bool in
                clients.remove(fd)
                Darwin.close(fd)
                return !stopped
            }
            guard active, let line else {
                admission.signal()
                return
            }
            Task { [onLine, admission] in
                await onLine(line)
                admission.signal()
            }
        }
    }

    private static func readLine(fd: Int32) -> Data? {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while line.count < ClaudePeerProtocol.maximumLineBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32((deadline - now) / 1_000_000) + 1)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return nil }
            let count = Darwin.read(fd, &chunk, min(chunk.count, ClaudePeerProtocol.maximumLineBytes - line.count))
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return nil }
            if let newline = chunk.prefix(count).firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[...newline])
                return line
            }
            line.append(contentsOf: chunk.prefix(count))
        }
        return nil
    }
}
