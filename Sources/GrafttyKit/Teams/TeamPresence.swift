import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// @spec TEAM-PRESENCE-1.2
/// @spec TEAM-IDLE-2.9
/// @spec TEAM-IDLE-2.10
/// Per-(team, worktree, runtime, pane) presence record. Distinct from
/// worktree existence: a record means a runtime registered itself, but
/// callers that need liveness must still validate `pid`. `paneSessionName`
/// is set when the registering process saw a `ZMX_SESSION` env var
/// (i.e. inside a graftty-launched zmx pane); nil otherwise.
public struct TeamPresenceRecord: Codable, Equatable, Sendable {
    public let teamID: String
    public let worktree: String
    public let runtime: TeamHookRuntime
    public let paneSessionName: String?
    public let pid: Int32
    public let processStartTimeMicroseconds: Int64?
    public let registeredAt: Date
    /// Stable provider session identity used to derive Graftty's canonical
    /// agent ID. This is intentionally separate from a provider-controlled
    /// display name.
    public let runtimeSessionID: String?
    public let nativeDisplayName: String?
    public let agentID: String?
    public let transport: TeamAgentTransport?
    /// Native provider children share their parent's worktree but are not
    /// independently addressable through `graftty team`.
    public let isSubagent: Bool?

    public init(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?,
        pid: Int32,
        processStartTimeMicroseconds: Int64? = nil,
        registeredAt: Date,
        runtimeSessionID: String? = nil,
        nativeDisplayName: String? = nil,
        agentID: String? = nil,
        transport: TeamAgentTransport? = nil,
        isSubagent: Bool = false
    ) {
        self.teamID = teamID
        self.worktree = worktree
        self.runtime = runtime
        self.paneSessionName = paneSessionName
        self.pid = pid
        self.processStartTimeMicroseconds = processStartTimeMicroseconds
        self.registeredAt = registeredAt
        self.runtimeSessionID = runtimeSessionID
        self.nativeDisplayName = nativeDisplayName
        self.agentID = agentID
        self.transport = transport
        self.isSubagent = isSubagent ? true : nil
    }
}

/// Native ingress metadata associated with one observed top-level agent.
/// Values are compatibility observations, not provider API contracts, so
/// delivery validates the endpoint again immediately before use.
public enum TeamAgentTransport: Codable, Equatable, Sendable {
    case claude(socketPath: String, protocolVersion: Int)
    case codex(
        binaryPath: String,
        socketPath: String,
        threadID: String,
        activeTurnID: String?
    )
}

/// On-disk storage for `TeamPresenceRecord`s under a directory the caller controls
/// (production: `~/.graftty/teams/`; tests: a tmp dir).
public struct TeamPresenceStorage: Sendable {
    private static let claudeBindingProcessLocksGuard = NSLock()
    private static var claudeBindingProcessLocks: [String: NSLock] = [:]

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func defaultRoot() -> URL {
        AppState.defaultDirectory.appendingPathComponent("teams", isDirectory: true)
    }

    public func write(_ record: TeamPresenceRecord) throws {
        let dir = presenceDirectory(teamID: record.teamID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = filePath(
            teamID: record.teamID,
            worktree: record.worktree,
            runtime: record.runtime,
            paneSessionName: record.paneSessionName,
            agentID: record.agentID
        )
        let encoder = JSONEncoder()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
        // An agent-ID-keyed record supersedes the pre-upgrade file that
        // keyed the same slot without an identity suffix. Leaving the old
        // file behind lists one live session as two agents, and the older
        // transport-less row wins default routing by registration time.
        if record.agentID != nil {
            let legacyURL = filePath(
                teamID: record.teamID,
                worktree: record.worktree,
                runtime: record.runtime,
                paneSessionName: record.paneSessionName,
                agentID: nil
            )
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try? FileManager.default.removeItem(at: legacyURL)
            }
        }
    }

    public func read(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?,
        agentID: String? = nil
    ) throws -> TeamPresenceRecord? {
        let url = filePath(
            teamID: teamID,
            worktree: worktree,
            runtime: runtime,
            paneSessionName: paneSessionName,
            agentID: agentID
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TeamPresenceRecord.self, from: data)
    }

    public func delete(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?,
        agentID: String? = nil
    ) throws {
        let url = filePath(
            teamID: teamID,
            worktree: worktree,
            runtime: runtime,
            paneSessionName: paneSessionName,
            agentID: agentID
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func listAll() throws -> [TeamPresenceRecord] {
        let fm = FileManager.default
        guard let teamDirs = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var allRecords: [TeamPresenceRecord] = []
        for teamDir in teamDirs {
            let presenceDir = teamDir.appendingPathComponent("presence", isDirectory: true)
            allRecords.append(contentsOf: records(in: presenceDir))
        }
        return allRecords
    }

    /// Reads only the team directory needed by endpoint-binding hooks instead
    /// of walking every repository registered with Graftty.
    public func list(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime
    ) throws -> [TeamPresenceRecord] {
        records(in: presenceDirectory(teamID: teamID)).filter {
            $0.teamID == teamID
                && $0.worktree == worktree
                && $0.runtime == runtime
        }
    }

    /// Serializes Claude identity replacement across hook CLI processes. The
    /// in-process lock is necessary because advisory file locks alone do not
    /// consistently serialize multiple file descriptors owned by one process.
    func withClaudeBindingLock<T>(
        teamID: String,
        _ body: () throws -> T
    ) throws -> T {
        let url = presenceDirectory(teamID: teamID)
            .appendingPathComponent(".claude-binding.lock")
        let processLock = Self.claudeBindingProcessLock(for: url)
        processLock.lock()
        defer { processLock.unlock() }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let permissions = S_IRUSR | S_IWUSR
        #if canImport(Darwin)
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT, permissions)
        #elseif canImport(Glibc)
        let fd = Glibc.open(url.path, O_RDWR | O_CREAT, mode_t(permissions))
        #else
        #error("Unsupported platform")
        #endif
        guard fd >= 0 else { throw Self.currentPOSIXError() }
        defer {
            _ = flock(fd, LOCK_UN)
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #elseif canImport(Glibc)
            _ = Glibc.close(fd)
            #endif
        }
        guard flock(fd, LOCK_EX) == 0 else {
            throw Self.currentPOSIXError()
        }
        return try body()
    }

    private func records(in directory: URL) -> [TeamPresenceRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file) else {
                return nil
            }
            return try? decoder.decode(TeamPresenceRecord.self, from: data)
        }
    }

    private static func claudeBindingProcessLock(for url: URL) -> NSLock {
        let key = url.standardizedFileURL.path
        claudeBindingProcessLocksGuard.lock()
        defer { claudeBindingProcessLocksGuard.unlock() }
        if let lock = claudeBindingProcessLocks[key] {
            return lock
        }
        let lock = NSLock()
        claudeBindingProcessLocks[key] = lock
        return lock
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func presenceDirectory(teamID: String) -> URL {
        rootDirectory
            .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
            .appendingPathComponent("presence", isDirectory: true)
    }

    private func filePath(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?,
        agentID: String? = nil
    ) -> URL {
        let paneSegment = paneSessionName ?? "_no_pane"
        let identitySegment = agentID.map { ".\($0)" } ?? ""
        let leaf = TeamInbox.fileComponent(
            "\(worktree).\(runtime.rawValue).\(paneSegment)\(identitySegment)"
        ) + ".json"
        return presenceDirectory(teamID: teamID).appendingPathComponent(leaf)
    }
}

/// In-memory view of presence files for hot paths such as key handling.
/// The CLI owns writes to `TeamPresenceStorage`, so the app refreshes this
/// index at event boundaries and on the stale-presence ticker.
public final class TeamPresenceIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [TeamPresenceRecord] = []
    private var recordsByPaneSessionName: [String: [TeamPresenceRecord]] = [:]

    public init(records: [TeamPresenceRecord] = []) {
        replace(with: records)
    }

    public func replace(with records: [TeamPresenceRecord]) {
        lock.lock()
        self.records = records
        self.recordsByPaneSessionName = Self.groupByPaneSessionName(records)
        lock.unlock()
    }

    public func allRecords() -> [TeamPresenceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func records(forPaneSessionName sessionName: String) -> [TeamPresenceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsByPaneSessionName[sessionName] ?? []
    }

    public func remove(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?
    ) {
        lock.lock()
        records = records.filter { record in
            !(record.teamID == teamID &&
              record.worktree == worktree &&
              record.runtime == runtime &&
              record.paneSessionName == paneSessionName)
        }
        recordsByPaneSessionName = Self.groupByPaneSessionName(records)
        lock.unlock()
    }

    private static func groupByPaneSessionName(
        _ records: [TeamPresenceRecord]
    ) -> [String: [TeamPresenceRecord]] {
        Dictionary(grouping: records.compactMap { record -> (String, TeamPresenceRecord)? in
            guard let sessionName = record.paneSessionName else { return nil }
            return (sessionName, record)
        }, by: { $0.0 }).mapValues { pairs in
            pairs.map(\.1)
        }
    }
}

/// @spec TEAM-PRESENCE-1.4
/// Stateless helper for the process-monitor's stale-record sweep. The
/// wrapper trap installed by the agent runtime hook is the primary
/// cleanup path; this fallback covers the SIGKILL / hard-crash cases
/// where the trap never fires and a presence file would otherwise
/// linger across the dead PID's lifetime.
public enum TeamPresenceMonitor {
    public static func cleanupStale(
        storage: TeamPresenceStorage,
        isAlive: (Int32) -> Bool = { TeamPresenceMonitor.kernelIsAlive($0) },
        isSameProcess: (TeamPresenceRecord) -> Bool = { record in
            guard let recordedStart = record.processStartTimeMicroseconds,
                  let currentStart = ProcessIdentityReader.startTimeMicroseconds(ofPID: record.pid)
            else { return false }
            return recordedStart == currentStart
        },
        eventLog: TeamEventLog? = TeamEventLog.defaultLog()
    ) {
        let records = (try? storage.listAll()) ?? []
        for record in records {
            let reason: String?
            if !isAlive(record.pid) {
                reason = "process_dead"
            } else if record.processStartTimeMicroseconds == nil {
                reason = nil
            } else if !isSameProcess(record) {
                reason = "process_identity_mismatch"
            } else {
                reason = nil
            }
            guard let reason else { continue }
            do {
                try storage.delete(
                    teamID: record.teamID,
                    worktree: record.worktree,
                    runtime: record.runtime,
                    paneSessionName: record.paneSessionName,
                    agentID: record.agentID
                )
                try? eventLog?.append(
                    .init(teamID: record.teamID, kind: .unregistered, detail: [
                        "worktree": record.worktree,
                        "runtime": record.runtime.rawValue,
                        "pid": String(record.pid),
                        "reason": reason,
                    ])
                )
            } catch {
                // Swallow — best-effort cleanup.
            }
        }
    }

    public static func kernelIsAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0): returns 0 if pid is alive (and signal-deliverable),
        // -1 + errno=ESRCH if not. Any other error (EPERM) means the
        // process exists but we can't signal it — still alive.
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
