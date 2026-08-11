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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
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
                return try? decoder.decode(RegistryRecord.self, from: data)
            }
    }

    /// Compares recorded and expected worktree paths through symlink
    /// resolution (`/tmp` vs `/private/tmp`) and `.`/`..` normalization so a
    /// cosmetically different spelling of the same directory still matches.
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func isSocket(atPath path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSocket
    }
}
