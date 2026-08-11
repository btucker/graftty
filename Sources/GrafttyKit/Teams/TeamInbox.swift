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
    public let agentID: String?

    public init(
        member: String,
        worktree: String,
        runtime: String?,
        agentID: String? = nil
    ) {
        self.member = member
        self.worktree = worktree
        self.runtime = runtime
        self.agentID = agentID
    }
}

extension TeamInboxEndpoint {
    public var canonicalAddress: String {
        guard let agentID else { return worktree }
        return "\(worktree)#\(agentID)"
    }

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

/// @spec TEAM-11.6
/// If the worktree watermark lock cannot be acquired within the configured
/// timeout, the application shall throw a lock-timeout error instead of
/// blocking the calling thread indefinitely.
public enum TeamInboxError: Error, Equatable, CustomStringConvertible {
    case watermarkLockTimeout
    case advanceTargetNotFound(String)
    case advanceTargetNotAddressed(messageID: String, worktree: String)

    public var description: String {
        switch self {
        case .watermarkLockTimeout:
            return "timed out waiting for the team inbox delivery lock"
        case .advanceTargetNotFound(let messageID):
            return "team inbox message not found: \(messageID)"
        case .advanceTargetNotAddressed(let messageID, let worktree):
            return "team inbox message \(messageID) is not addressed to \(worktree)"
        }
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
    /// TEAM-11.6: upper bound on how long a watermark operation may wait
    /// for the inter-process lock. Callers that hit the bound fail with
    /// `TeamInboxError.watermarkLockTimeout` and retry on their own
    /// cadence (watchers poll; hooks redeliver) instead of blocking their
    /// thread behind a stuck or convoying lock holder indefinitely.
    private let watermarkLockTimeout: TimeInterval

    public init(
        rootDirectory: URL,
        idGenerator: @escaping () -> String = TeamInbox.defaultID,
        now: @escaping () -> Date = { Date() },
        watermarkLockTimeout: TimeInterval = 2.0
    ) {
        self.rootDirectory = rootDirectory
        self.idGenerator = idGenerator
        self.now = now
        self.watermarkLockTimeout = watermarkLockTimeout
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
        return unreadMessages(
            from: allMessages,
            recipientWorktree: recipientWorktree,
            after: lastSeenID,
            priorities: priorities
        )
    }

    func unreadMessages(
        from allMessages: [TeamInboxMessage],
        recipientWorktree: String,
        after lastSeenID: String?,
        priorities: Set<TeamInboxPriority>? = nil
    ) -> [TeamInboxMessage] {
        unreadMessages(
            from: allMessages,
            recipientWorktree: recipientWorktree,
            afterIndex: messageIndex(lastSeenID, in: allMessages),
            priorities: priorities
        )
    }

    private func unreadMessages(
        from allMessages: [TeamInboxMessage],
        recipientWorktree: String,
        afterIndex: Int?,
        priorities: Set<TeamInboxPriority>? = nil
    ) -> [TeamInboxMessage] {
        let candidates: ArraySlice<TeamInboxMessage>
        if let index = afterIndex {
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

    /// Returns the leading rows that `runtime` may consume. A row targeted to
    /// another runtime stops the prefix so the shared worktree watermark never
    /// advances past a message that still needs its own delivery path.
    static func runtimeDeliverablePrefix(
        _ messages: [TeamInboxMessage],
        runtime: String,
        agentID: String? = nil,
        acceptsUntargeted: Bool = true
    ) -> [TeamInboxMessage] {
        Array(messages.prefix {
            isDeliverable(
                $0,
                toRuntime: runtime,
                agentID: agentID,
                acceptsUntargeted: acceptsUntargeted
            )
        })
    }

    static func isDeliverable(
        _ message: TeamInboxMessage,
        toRuntime runtime: String,
        agentID: String? = nil,
        acceptsUntargeted: Bool = true
    ) -> Bool {
        if message.to.runtime == nil, message.to.agentID == nil {
            return acceptsUntargeted
        }
        guard message.to.runtime == nil || message.to.runtime == runtime else {
            return false
        }
        guard let targetedAgentID = message.to.agentID else { return true }
        return targetedAgentID == agentID
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

    /// Selects an unread snapshot while holding the same lock used by all
    /// shared-watermark writers. A committed watermark can therefore never
    /// refer to a row newer than the log snapshot used for this read.
    func worktreeUnreadSnapshot(
        teamID: String,
        recipientWorktree: String
    ) throws -> (messages: [TeamInboxMessage], throughID: String?) {
        try withWorktreeWatermarkLock(teamID: teamID, worktree: recipientWorktree) {
            let watermarkID = try worktreeWatermark(
                teamID: teamID,
                worktree: recipientWorktree
            )?.lastDeliveredToAnySessionID
            let allMessages = try messages(teamID: teamID)
            let unread = unreadMessages(
                from: allMessages,
                recipientWorktree: recipientWorktree,
                after: watermarkID
            )
            return (unread, unread.last?.id)
        }
    }

    public func advanceRead(
        teamID: String,
        recipientWorktree: String,
        throughID: String
    ) throws {
        try withWorktreeWatermarkLock(teamID: teamID, worktree: recipientWorktree) {
            let allMessages = try messages(teamID: teamID)
            let currentID = try worktreeWatermark(
                teamID: teamID,
                worktree: recipientWorktree
            )?.lastDeliveredToAnySessionID

            guard let targetIndex = allMessages.lastIndex(where: { $0.id == throughID }) else {
                throw TeamInboxError.advanceTargetNotFound(throughID)
            }
            let target = allMessages[targetIndex]
            guard target.to.worktree == recipientWorktree else {
                throw TeamInboxError.advanceTargetNotAddressed(
                    messageID: throughID,
                    worktree: recipientWorktree
                )
            }

            let currentIndex = messageIndex(currentID, in: allMessages)
            if let currentIndex, currentIndex >= targetIndex {
                return
            }

            try writeWorktreeWatermarkUnlocked(
                TeamInboxWorktreeWatermark(
                    worktree: recipientWorktree,
                    lastDeliveredToAnySessionID: target.id
                ),
                teamID: teamID
            )
        }
    }

    /// Reads the log once and chooses the later known append-order anchor for
    /// hook delivery. If a persisted non-nil anchor is absent from the
    /// retained log, preserve the legacy session-cursor fallback instead of
    /// guessing its former order.
    func hookUnreadMessages(
        teamID: String,
        recipientWorktree: String,
        sessionLastSeenID: String?
    ) throws -> (readPosition: String?, messages: [TeamInboxMessage]) {
        let watermarkID = try worktreeWatermark(
            teamID: teamID,
            worktree: recipientWorktree
        )?.lastDeliveredToAnySessionID
        let allMessages = try messages(teamID: teamID)
        let readPosition = effectiveHookReadPosition(
            sessionLastSeenID: sessionLastSeenID,
            watermarkID: watermarkID,
            messages: allMessages
        )
        return (
            readPosition.id,
            unreadMessages(
                from: allMessages,
                recipientWorktree: recipientWorktree,
                afterIndex: readPosition.index
            )
        )
    }

    private func effectiveHookReadPosition(
        sessionLastSeenID: String?,
        watermarkID: String?,
        messages: [TeamInboxMessage]
    ) -> (id: String?, index: Int?) {
        let sessionIndex = messageIndex(sessionLastSeenID, in: messages)
        if sessionLastSeenID != nil, sessionIndex == nil {
            return (sessionLastSeenID, nil)
        }

        let watermarkIndex = messageIndex(watermarkID, in: messages)
        if watermarkID != nil, watermarkIndex == nil {
            return (sessionLastSeenID, sessionIndex)
        }

        if (watermarkIndex ?? -1) > (sessionIndex ?? -1) {
            return (watermarkID, watermarkIndex)
        }
        return (sessionLastSeenID, sessionIndex)
    }

    /// Atomically claims the next durable message that this runtime can
    /// consume. The worktree watermark is the cross-session claim token;
    /// holding its inter-process lock while selecting the ordered row and
    /// committing that watermark prevents two watcher processes from
    /// surfacing the same message. The session cursor mirrors successful
    /// claims for per-session diagnostics and catch-up.
    ///
    /// A runtime-targeted row at the head of the worktree's unread queue
    /// blocks other runtimes rather than being skipped. That keeps the
    /// shared watermark ordered and prevents advancing past an earlier
    /// message that still needs its own delivery path.
    public func claimNextUnreadMessage(
        teamID: String,
        sessionID: String,
        recipientWorktree: String,
        runtime: String,
        agentID: String? = nil
    ) throws -> TeamInboxMessage? {
        try withWorktreeWatermarkLock(teamID: teamID, worktree: recipientWorktree) {
            guard let cursor = try cursor(teamID: teamID, sessionID: sessionID),
                  cursor.worktree == recipientWorktree,
                  cursor.runtime == runtime else {
                return nil
            }

            let allMessages = try messages(teamID: teamID)
            let watermarkID = try worktreeWatermark(
                teamID: teamID,
                worktree: recipientWorktree
            )?.lastDeliveredToAnySessionID
            let cursorIndex = messageIndex(cursor.lastSeenID, in: allMessages)
            let watermarkIndex = messageIndex(watermarkID, in: allMessages)
            let lastDeliveredIndex = max(cursorIndex ?? -1, watermarkIndex ?? -1)
            let unreadStart = allMessages.index(
                allMessages.startIndex,
                offsetBy: lastDeliveredIndex + 1
            )

            guard let message = allMessages[unreadStart...].first(where: {
                $0.to.worktree == recipientWorktree
            }) else {
                return nil
            }
            guard Self.isDeliverable(message, toRuntime: runtime, agentID: agentID) else {
                return nil
            }

            // The shared watermark is the authoritative cross-session claim.
            // Commit it first under the lock, then mirror the session cursor.
            // If the cursor write fails, still surface the claimed message:
            // the watermark prevents a replacement watcher from duplicating
            // it and supplies that watcher with the effective delivery floor.
            try writeWorktreeWatermarkUnlocked(
                TeamInboxWorktreeWatermark(
                    worktree: recipientWorktree,
                    lastDeliveredToAnySessionID: message.id
                ),
                teamID: teamID
            )
            try? writeCursor(
                TeamInboxCursor(
                    sessionID: sessionID,
                    worktree: recipientWorktree,
                    runtime: runtime,
                    lastSeenID: message.id
                ),
                teamID: teamID
            )
            return message
        }
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

    private func messageIndex(
        _ messageID: String?,
        in messages: [TeamInboxMessage]
    ) -> Int? {
        guard let messageID else { return nil }
        return messages.lastIndex(where: { $0.id == messageID })
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
        let deadline = Date().addingTimeInterval(watermarkLockTimeout)
        let url = worktreeWatermarkLockURL(teamID: teamID, worktree: worktree)
        let processLock = Self.worktreeWatermarkProcessLock(for: url)
        guard processLock.lock(before: deadline) else {
            throw TeamInboxError.watermarkLockTimeout
        }
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

        try acquireRecordLock(fd: fd, deadline: deadline)
        #if canImport(Darwin)
        defer { _ = Darwin.lockf(fd, F_ULOCK, 0) }
        #elseif canImport(Glibc)
        defer { _ = Glibc.lockf(fd, F_ULOCK, 0) }
        #endif
        return try body()
    }

    /// TEAM-11.6: non-blocking `F_TLOCK` in a short retry loop instead of
    /// an unbounded `F_LOCK`, so a stuck or convoying lock holder can
    /// delay a caller by at most `watermarkLockTimeout`.
    private func acquireRecordLock(fd: Int32, deadline: Date) throws {
        while true {
            #if canImport(Darwin)
            let result = Darwin.lockf(fd, F_TLOCK, 0)
            #elseif canImport(Glibc)
            let result = Glibc.lockf(fd, F_TLOCK, 0)
            #endif
            if result == 0 { return }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EACCES else {
                throw currentPOSIXError()
            }
            guard Date() < deadline else {
                throw TeamInboxError.watermarkLockTimeout
            }
            usleep(10_000)
        }
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
