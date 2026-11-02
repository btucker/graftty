import Foundation
import GrafttyProtocol

public struct AgentLifecycleEvent: Codable, Sendable {
    public let agentID: String
    public let assignmentID: UUID
    public let sessionID: PaneSessionID
    public let exitCode: Int
    public var recordedAt: Date?

    public init(agentID: String, assignmentID: UUID, sessionID: PaneSessionID, exitCode: Int) {
        self.agentID = agentID; self.assignmentID = assignmentID
        self.sessionID = sessionID; self.exitCode = exitCode
        self.recordedAt = Date()
    }
}

/// Provider exit survives a control-socket outage. Files retire only after state persistence.
public struct AgentLifecycleHandoff: Sendable {
    public let directory: URL
    public init(directory: URL) {
        self.directory = directory
    }

    public func publish(_ event: AgentLifecycleEvent) throws {
        try AttentionFileHandoff(rootDirectory: directory).ensureDirectory()
        try JSONEncoder().encode(event).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
    }

    /// The foreground shell publishes directly, even if its PATH or CLI override is unavailable.
    func shellExitReport(agentID: String, assignmentID: UUID, sessionID: PaneSessionID) throws -> String {
        try AttentionFileHandoff(rootDirectory: directory).ensureDirectory()
        struct Identity: Encodable {
            let agentID: String
            let assignmentID: UUID
            let sessionID: PaneSessionID
        }
        let identity = Identity(agentID: agentID, assignmentID: assignmentID, sessionID: sessionID)
        // Only the numeric exit status is dynamic. Encode all identity fields before shell quoting.
        let encoded = try JSONEncoder().encode(identity)
        let prefix = String(decoding: encoded.dropLast(), as: UTF8.self) + ",\"exitCode\":"
        let file = directory.appendingPathComponent(UUID().uuidString + ".json")
        let temporary = file.appendingPathExtension("pending")
        let quote = WorktreeAgentLaunchCommand.shellLiteral
        return "(umask 077; /usr/bin/printf '%s%s}\\n' \(quote(prefix)) \"$_graftty_exit\" > \(quote(temporary.path)) && /bin/mv -f \(quote(temporary.path)) \(quote(file.path)))"
    }

    public func pending() throws -> [(URL, AgentLifecycleEvent)] {
        try AttentionFileHandoff(rootDirectory: directory).ensureDirectory()
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]).compactMap { file in
            guard file.pathExtension == "json" else { return nil }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 4096,
                  var event = try? JSONDecoder().decode(AgentLifecycleEvent.self, from: Data(contentsOf: file)) else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            // Shell publications use the write time so delayed drains can distinguish later native bindings.
            if event.recordedAt == nil { event.recordedAt = values.contentModificationDate }
            return (file, event)
        }
    }
}
