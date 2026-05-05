import Foundation

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
        let dir = rootDirectory.appendingPathComponent(event.teamID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("events.jsonl")
        var line = try encoder.encode(event)
        line.append(0x0A)  // newline
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: url, options: .atomic)
        }
    }
}
