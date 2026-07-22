import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum TeamInboxPriority: String, Codable, Sendable, Equatable {
    case normal
    case urgent
}

public struct TeamInboxEndpoint: Codable, Sendable, Equatable, Hashable {
    public let member: String
    public let worktree: String
    public let runtime: String?

    public init(member: String, worktree: String, runtime: String?) {
        self.member = member
        self.worktree = worktree
        self.runtime = runtime
    }
}

extension TeamInboxEndpoint {
    /// @spec TEAM-5.4
    /// Synthetic sender used by automated team events (PR/CI/membership)
    /// where there is no human author. The activity window and hook
    /// renderers detect `member == "system"` and present these rows
    /// differently from chat messages.
    public static func system(repoPath: String) -> TeamInboxEndpoint {
        TeamInboxEndpoint(member: "system", worktree: repoPath, runtime: nil)
    }
}

public struct TeamInboxMessage: Codable, Sendable, Equatable {
    public let id: String
    public let batchID: String?
    public let createdAt: Date
    public let team: String
    public let repoPath: String
    public let from: TeamInboxEndpoint
    public let to: TeamInboxEndpoint
    public let priority: TeamInboxPriority
    public let kind: String
    public let body: String
    /// Rendered `teamPrompt` template output for an automated event, or nil
    /// for authored `team_message` rows, when the template was empty / failed
    /// to render, or for a pre-split row from disk. Hook delivery
    /// (`TeamHookRenderer.format`) emits this for automated events when present
    /// and falls through to `body` otherwise; activity log / watcher /
    /// `team inbox` CLI ignore it. See @spec TEAM-1.6.
    public let agentPrompt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case batchID = "batch_id"
        case createdAt = "created_at"
        case team
        case repoPath = "repo_path"
        case from, to, priority, kind, body
        case agentPrompt = "agent_prompt"
    }

    public init(
        id: String,
        batchID: String?,
        createdAt: Date,
        team: String,
        repoPath: String,
        from: TeamInboxEndpoint,
        to: TeamInboxEndpoint,
        priority: TeamInboxPriority,
        kind: String = "team_message",
        body: String,
        agentPrompt: String? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.createdAt = createdAt
        self.team = team
        self.repoPath = repoPath
        self.from = from
        self.to = to
        self.priority = priority
        self.kind = kind
        self.body = body
        self.agentPrompt = agentPrompt
    }
}

public struct TeamInboxCursor: Codable, Sendable, Equatable {
    public let sessionID: String
    public let worktree: String
    public let runtime: String
    public let lastSeenID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case worktree
        case runtime
        case lastSeenID = "last_seen_id"
    }

    public init(sessionID: String, worktree: String, runtime: String, lastSeenID: String?) {
        self.sessionID = sessionID
        self.worktree = worktree
        self.runtime = runtime
        self.lastSeenID = lastSeenID
    }
}

public struct TeamInboxWorktreeWatermark: Codable, Sendable, Equatable {
    public let worktree: String
    public let lastDeliveredToAnySessionID: String?

    enum CodingKeys: String, CodingKey {
        case worktree
        case lastDeliveredToAnySessionID = "last_delivered_to_any_session_id"
    }

    public init(worktree: String, lastDeliveredToAnySessionID: String?) {
        self.worktree = worktree
        self.lastDeliveredToAnySessionID = lastDeliveredToAnySessionID
    }
}

public final class TeamInbox {
    private static let worktreeWatermarkProcessLocksGuard = NSLock()
    private static var worktreeWatermarkProcessLocks: [String: NSLock] = [:]

    public let rootDirectory: URL
    private let idGenerator: () -> String
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootDirectory: URL,
        idGenerator: @escaping () -> String = TeamInbox.defaultID,
        now: @escaping () -> Date = { Date() }
    ) {
        self.rootDirectory = rootDirectory
        self.idGenerator = idGenerator
        self.now = now
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    public func appendMessage(
        teamID: String,
        teamName: String,
        repoPath: String,
        from: TeamInboxEndpoint,
        to: TeamInboxEndpoint,
        priority: TeamInboxPriority,
        kind: String = "team_message",
        body: String,
        agentPrompt: String? = nil
    ) throws -> TeamInboxMessage {
        let message = TeamInboxMessage(
            id: idGenerator(),
            batchID: nil,
            createdAt: now(),
            team: teamName,
            repoPath: repoPath,
            from: from,
            to: to,
            priority: priority,
            kind: kind,
            body: body,
            agentPrompt: agentPrompt
        )
        try append(message, teamID: teamID)
        return message
    }

    @discardableResult
    public func appendBroadcast(
        teamID: String,
        teamName: String,
        repoPath: String,
        from: TeamInboxEndpoint,
        recipients: [TeamInboxEndpoint],
        priority: TeamInboxPriority,
        body: String
    ) throws -> [TeamInboxMessage] {
        let batchID = idGenerator()
        let messages = recipients.map { recipient in
            TeamInboxMessage(
                id: idGenerator(),
                batchID: batchID,
                createdAt: now(),
                team: teamName,
                repoPath: repoPath,
                from: from,
                to: recipient,
                priority: priority,
                body: body
            )
        }
        for message in messages {
            try append(message, teamID: teamID)
        }
        return messages
    }

    public func messages(teamID: String) throws -> [TeamInboxMessage] {
        let url = messagesURL(teamID: teamID)
        guard let data = try dataIfFileExists(at: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(TeamInboxMessage.self, from: data)
        }
    }

    public func unreadMessages(
        teamID: String,
        recipientWorktree: String,
        after lastSeenID: String?,
        priorities: Set<TeamInboxPriority>? = nil
    ) throws -> [TeamInboxMessage] {
        let allMessages = try messages(teamID: teamID)
        let candidates: ArraySlice<TeamInboxMessage>
        if let lastSeenID, let index = allMessages.lastIndex(where: { $0.id == lastSeenID }) {
            candidates = allMessages[allMessages.index(after: index)...]
        } else {
            candidates = allMessages[...]
        }
        return candidates.filter { message in
            guard message.to.worktree == recipientWorktree else { return false }
            if let priorities, !priorities.contains(message.priority) { return false }
            return true
        }
    }

    public func writeCursor(_ cursor: TeamInboxCursor, teamID: String) throws {
        let url = cursorURL(teamID: teamID, sessionID: cursor.sessionID)
        try ensureParentDirectory(for: url)
        let data = try encoder.encode(cursor)
        try data.write(to: url, options: .atomic)
    }

    public func cursor(teamID: String, sessionID: String) throws -> TeamInboxCursor? {
        let url = cursorURL(teamID: teamID, sessionID: sessionID)
        guard let data = try dataIfFileExists(at: url) else { return nil }
        return try decoder.decode(TeamInboxCursor.self, from: data)
    }

    public func writeWorktreeWatermark(
        _ watermark: TeamInboxWorktreeWatermark,
        teamID: String
    ) throws {
        try withWorktreeWatermarkLock(teamID: teamID, worktree: watermark.worktree) {
            if try shouldWriteWorktreeWatermarkUnlocked(
                teamID: teamID,
                worktree: watermark.worktree,
                proposedID: watermark.lastDeliveredToAnySessionID,
                allowUnknownProposedID: true
            ) {
                try writeWorktreeWatermarkUnlocked(watermark, teamID: teamID)
            }
        }
    }

    public func worktreeWatermark(
        teamID: String,
        worktree: String
    ) throws -> TeamInboxWorktreeWatermark? {
        let url = watermarkURL(teamID: teamID, worktree: worktree)
        guard let data = try dataIfFileExists(at: url) else { return nil }
        return try decoder.decode(TeamInboxWorktreeWatermark.self, from: data)
    }

    @discardableResult
    public func compareAndAdvanceWorktreeWatermark(
        teamID: String,
        worktree: String,
        to proposedMessageID: String
    ) throws -> Bool {
        try withWorktreeWatermarkLock(teamID: teamID, worktree: worktree) {
            if try shouldWriteWorktreeWatermarkUnlocked(
                teamID: teamID,
                worktree: worktree,
                proposedID: proposedMessageID,
                allowUnknownProposedID: false
            ) {
                try writeWorktreeWatermarkUnlocked(
                    TeamInboxWorktreeWatermark(
                        worktree: worktree,
                        lastDeliveredToAnySessionID: proposedMessageID
                    ),
                    teamID: teamID
                )
                return true
            }
            return false
        }
    }

    private func shouldWriteWorktreeWatermarkUnlocked(
        teamID: String,
        worktree: String,
        proposedID: String?,
        allowUnknownProposedID: Bool
    ) throws -> Bool {
        let currentID = try worktreeWatermark(
            teamID: teamID,
            worktree: worktree
        )?.lastDeliveredToAnySessionID
        guard currentID != proposedID else {
            return false
        }
        guard let currentID else {
            return true
        }
        guard let proposedID else {
            return false
        }

        let messages = try messages(teamID: teamID)
        guard let proposedIndex = messages.lastIndex(where: { $0.id == proposedID }) else {
            return allowUnknownProposedID
        }
        guard let currentIndex = messages.lastIndex(where: { $0.id == currentID }) else {
            return true
        }
        return proposedIndex > currentIndex
    }

    private func writeWorktreeWatermarkUnlocked(
        _ watermark: TeamInboxWorktreeWatermark,
        teamID: String
    ) throws {
        let url = watermarkURL(teamID: teamID, worktree: watermark.worktree)
        try ensureParentDirectory(for: url)
        let data = try encoder.encode(watermark)
        try data.write(to: url, options: .atomic)
    }

    private func append(_ message: TeamInboxMessage, teamID: String) throws {
        let url = messagesURL(teamID: teamID)
        try ensureParentDirectory(for: url)
        let data = try encoder.encode(message)
        let fd = try openForAppend(at: url.path)
        defer { _ = close(fd) }
        try writeAll(data, to: fd)
        try writeAll(Data([0x0A]), to: fd)
    }

    private func dataIfFileExists(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain &&
                  error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func openForAppend(at path: String) throws -> Int32 {
        let permissions = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        #if canImport(Darwin)
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, permissions)
        #elseif canImport(Glibc)
        let fd = Glibc.open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(permissions))
        #else
        #error("Unsupported platform")
        #endif
        guard fd >= 0 else { throw currentPOSIXError() }
        return fd
    }

    private func withWorktreeWatermarkLock<T>(
        teamID: String,
        worktree: String,
        _ body: () throws -> T
    ) throws -> T {
        let url = worktreeWatermarkLockURL(teamID: teamID, worktree: worktree)
        let processLock = Self.worktreeWatermarkProcessLock(for: url)
        processLock.lock()
        defer { processLock.unlock() }

        try ensureParentDirectory(for: url)
        let permissions = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        #if canImport(Darwin)
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT, permissions)
        #elseif canImport(Glibc)
        let fd = Glibc.open(url.path, O_RDWR | O_CREAT, mode_t(permissions))
        #else
        #error("Unsupported platform")
        #endif
        guard fd >= 0 else { throw currentPOSIXError() }
        defer { close(fd) }

        #if canImport(Darwin)
        guard Darwin.lockf(fd, F_LOCK, 0) == 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.lockf(fd, F_ULOCK, 0) }
        #elseif canImport(Glibc)
        guard Glibc.lockf(fd, F_LOCK, 0) == 0 else { throw currentPOSIXError() }
        defer { _ = Glibc.lockf(fd, F_ULOCK, 0) }
        #endif
        return try body()
    }

    private static func worktreeWatermarkProcessLock(for url: URL) -> NSLock {
        let key = url.standardizedFileURL.path
        worktreeWatermarkProcessLocksGuard.lock()
        defer { worktreeWatermarkProcessLocksGuard.unlock() }
        if let lock = worktreeWatermarkProcessLocks[key] {
            return lock
        }
        let lock = NSLock()
        worktreeWatermarkProcessLocks[key] = lock
        return lock
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                #if canImport(Darwin)
                let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                #elseif canImport(Glibc)
                let written = Glibc.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                offset += written
            }
        }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func messagesURL(teamID: String) -> URL {
        Self.messagesURLFor(rootDirectory: rootDirectory, teamID: teamID)
    }

    /// Static helper used by `TeamInboxObserver` so the FSEvents tail
    /// computes the same path as the writer without needing a live
    /// `TeamInbox` instance reference. Mirrors the directory layout
    /// `<rootDirectory>/<sanitized-teamID>/messages.jsonl` produced by
    /// `appendMessage` / `messages(teamID:)`.
    public static func messagesURLFor(rootDirectory: URL, teamID: String) -> URL {
        rootDirectory
            .appendingPathComponent(fileComponent(teamID), isDirectory: true)
            .appendingPathComponent("messages.jsonl")
    }

    private func cursorURL(teamID: String, sessionID: String) -> URL {
        teamDirectory(teamID: teamID)
            .appendingPathComponent("cursors", isDirectory: true)
            .appendingPathComponent(Self.fileComponent(sessionID) + ".json")
    }

    private func watermarkURL(teamID: String, worktree: String) -> URL {
        teamDirectory(teamID: teamID)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(Self.fileComponent(worktree) + ".json")
    }

    private func worktreeWatermarkLockURL(teamID: String, worktree: String) -> URL {
        teamDirectory(teamID: teamID)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(Self.fileComponent(worktree) + ".lock")
    }

    private func teamDirectory(teamID: String) -> URL {
        rootDirectory.appendingPathComponent(Self.fileComponent(teamID), isDirectory: true)
    }

    private func ensureParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// Sanitizes an arbitrary string so it can be safely used as a single
    /// filesystem path component. Replaces any character outside
    /// `[A-Za-z0-9._-]` with `_`. Used by every Teams subsystem that maps
    /// `teamID`/`sessionID`/`worktree` into a directory or filename — keeps
    /// path-separator characters in those identifiers from escaping the
    /// team subtree.
    public static func fileComponent(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-":
                result.unicodeScalars.append(scalar)
            default:
                result.append("_")
            }
        }
        return result.isEmpty ? "_" : result
    }

    public static func defaultID() -> String {
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        return "\(String(format: "%016lld", micros))-\(UUID().uuidString)"
    }
}
