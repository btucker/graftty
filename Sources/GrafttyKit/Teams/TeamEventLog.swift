import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One JSON-lines record per observable team-presence event. Feeds the
/// Team Activity Log window plus future debugging — append-only, never
/// rewritten in place.
public struct TeamEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case registered
        case unregistered
        case watcherSpawned
        case watcherSuperseded
        case watcherWoke
        case watcherExited
        case nudgeSent
        case nudgeSkipped
        case agentStateTransition
        case zmxNudgeAttempt
    }

    public let teamID: String
    public let timestamp: Date
    public let kind: Kind
    public let detail: [String: String]

    public init(teamID: String, kind: Kind, detail: [String: String] = [:], timestamp: Date = Date()) {
        self.teamID = teamID
        self.timestamp = timestamp
        self.kind = kind
        self.detail = detail
    }
}

/// Append-only writer for `~/.graftty/teams/<teamID>/events.jsonl`. Lock
/// is in-process; cross-process appends still work because POSIX `write`
/// to an `O_APPEND` fd is atomic for line-sized payloads, but tests
/// exercise the in-process concurrent path.
public final class TeamEventLog: @unchecked Sendable {
    private let rootDirectory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public static func defaultLog() -> TeamEventLog {
        TeamEventLog(rootDirectory: TeamPresenceStorage.defaultRoot())
    }

    public func append(_ event: TeamEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = rootDirectory.appendingPathComponent(
            TeamInbox.fileComponent(event.teamID),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("events.jsonl")
        var line = try encoder.encode(event)
        line.append(0x0A)  // newline
        // O_APPEND for cross-process atomicity: POSIX guarantees a single
        // `write` to an `O_APPEND` fd appends the entire payload atomically
        // when the payload is ≤ PIPE_BUF (≥ 512 bytes). The `NSLock` above
        // serializes the JSONEncoder; this gives us cross-process safety.
        let permissions = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        #if canImport(Darwin)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, permissions)
        #elseif canImport(Glibc)
        let fd = Glibc.open(url.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(permissions))
        #endif
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        try line.withUnsafeBytes { rawBuffer in
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
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }
}
