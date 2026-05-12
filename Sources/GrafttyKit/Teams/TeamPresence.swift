import Foundation

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
    public let registeredAt: Date

    public init(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?,
        pid: Int32,
        registeredAt: Date
    ) {
        self.teamID = teamID
        self.worktree = worktree
        self.runtime = runtime
        self.paneSessionName = paneSessionName
        self.pid = pid
        self.registeredAt = registeredAt
    }
}

/// On-disk storage for `TeamPresenceRecord`s under a directory the caller controls
/// (production: `~/.graftty/teams/`; tests: a tmp dir).
public struct TeamPresenceStorage: Sendable {
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
            paneSessionName: record.paneSessionName
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func read(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?
    ) throws -> TeamPresenceRecord? {
        let url = filePath(
            teamID: teamID,
            worktree: worktree,
            runtime: runtime,
            paneSessionName: paneSessionName
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
        paneSessionName: String?
    ) throws {
        let url = filePath(
            teamID: teamID,
            worktree: worktree,
            runtime: runtime,
            paneSessionName: paneSessionName
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func listAll() throws -> [TeamPresenceRecord] {
        let fm = FileManager.default
        guard let teamDirs = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var records: [TeamPresenceRecord] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for teamDir in teamDirs {
            let presenceDir = teamDir.appendingPathComponent("presence", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: presenceDir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let record = try? decoder.decode(TeamPresenceRecord.self, from: data) {
                    records.append(record)
                }
            }
        }
        return records
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
        paneSessionName: String?
    ) -> URL {
        let paneSegment = paneSessionName ?? "_no_pane"
        let leaf = TeamInbox.fileComponent("\(worktree).\(runtime.rawValue).\(paneSegment)") + ".json"
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
        eventLog: TeamEventLog? = TeamEventLog.defaultLog()
    ) {
        let records = (try? storage.listAll()) ?? []
        for record in records where !isAlive(record.pid) {
            do {
                try storage.delete(
                    teamID: record.teamID,
                    worktree: record.worktree,
                    runtime: record.runtime,
                    paneSessionName: record.paneSessionName
                )
                try? eventLog?.append(
                    .init(teamID: record.teamID, kind: .unregistered, detail: [
                        "worktree": record.worktree,
                        "runtime": record.runtime.rawValue,
                        "pid": String(record.pid),
                        "reason": "process_dead",
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
