import Foundation

public struct ClaudePeerSessionRegistry: Sendable {
    private struct RegistryRecord: Decodable {
        let pid: Int32
        let sessionID: String
        let cwd: String
        let name: String?
        let kind: String?
        let parentSessionID: String?
        let peerProtocol: Int
        let messagingSocketPath: String

        enum CodingKeys: String, CodingKey {
            case pid, cwd, name, kind, peerProtocol, messagingSocketPath
            case sessionID = "sessionId"
            case parentSessionID = "parentSessionId"
        }
    }

    public let directory: URL
    private let processStartTimeMicroseconds: @Sendable (Int32) -> Int64?
    private let socketIsReachable: @Sendable (String) -> Bool

    public init(
        directory: URL = Self.defaultDirectory(),
        processStartTimeMicroseconds: @escaping @Sendable (Int32) -> Int64? = {
            ProcessIdentityReader.startTimeMicroseconds(ofPID: $0)
        },
        socketIsReachable: @escaping @Sendable (String) -> Bool = {
            Self.isSocket(atPath: $0)
        }
    ) {
        self.directory = directory
        self.processStartTimeMicroseconds = processStartTimeMicroseconds
        self.socketIsReachable = socketIsReachable
    }

    public static func defaultDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let configuredRoot = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = configuredRoot.flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        return root
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public func presenceRecord(
        sessionID: String,
        expectedWorktree: String,
        teamID: String,
        paneSessionName: String?,
        agentID: String? = nil,
        registeredAt: Date = Date()
    ) -> TeamPresenceRecord? {
        guard let record = records().first(where: { $0.sessionID == sessionID }),
              Self.canonicalPath(record.cwd) == Self.canonicalPath(expectedWorktree),
              record.peerProtocol == ClaudePeerProtocol.version,
              record.parentSessionID == nil,
              record.kind?.lowercased() != "subagent",
              record.messagingSocketPath.hasPrefix("/"),
              socketIsReachable(record.messagingSocketPath),
              let processStart = processStartTimeMicroseconds(record.pid) else {
            return nil
        }
        let identity = agentID.flatMap(TeamAgentIdentity.init(rawValue:))
            ?? TeamAgentIdentity(runtime: .claude, nativeSessionID: record.sessionID)
        return TeamPresenceRecord(
            teamID: teamID,
            worktree: expectedWorktree,
            runtime: .claude,
            paneSessionName: paneSessionName,
            pid: record.pid,
            processStartTimeMicroseconds: processStart,
            registeredAt: registeredAt,
            runtimeSessionID: record.sessionID,
            nativeDisplayName: record.name,
            agentID: identity.rawValue,
            transport: .claude(
                socketPath: record.messagingSocketPath,
                protocolVersion: record.peerProtocol
            )
        )
    }

    private func records() -> [RegistryRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return Self.decodeRecord(data, decoder: decoder)
            }
    }

    /// Claude rewrites a row in place, and a shorter rewrite can leave bytes
    /// of the previous object behind it (Claude 2.1.314 left a trailing `}`
    /// after an ENOSPC rewrite). The leading object is the current row; a row
    /// whose object never completes stays unreadable (AGENT-6.63).
    private static func decodeRecord(_ data: Data, decoder: JSONDecoder) -> RegistryRecord? {
        if let record = try? decoder.decode(RegistryRecord.self, from: data) {
            return record
        }
        guard let end = leadingObjectEnd(in: data) else { return nil }
        return try? decoder.decode(RegistryRecord.self, from: data.prefix(end))
    }

    /// The byte count of the first complete top-level JSON object in `data`,
    /// or nil when no object closes.
    private static func leadingObjectEnd(in data: Data) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, byte) in data.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return offset + 1 }
                if depth < 0 { return nil }
            default:
                break
            }
        }
        return nil
    }

    /// Compares recorded and expected worktree paths through symlink
    /// resolution (`/tmp` vs `/private/tmp`) and `.`/`..` normalization so a
    /// cosmetically different spelling of the same directory still matches.
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func isSocket(atPath path: String) -> Bool {
        // Codex may expose its app-server socket as a symlink into its daemon
        // directory. FileManager reports the link's type unless we resolve it.
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSocket
    }
}
