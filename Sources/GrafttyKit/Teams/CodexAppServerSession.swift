import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CodexAppServerSessionRecord: Codable, Equatable, Sendable {
    public let teamID: String
    public let worktree: String
    public let paneSessionName: String
    public let socketPath: String
    public let realBinaryPath: String
    public let appServerPID: Int32
    public let appServerProcessStartTimeMicroseconds: Int64?
    public let ownerPID: Int32?
    public let ownerProcessStartTimeMicroseconds: Int64?
    public let registeredAt: Date
    public let agentID: String?
    public let threadID: String?
    public let activeTurnID: String?

    public init(
        teamID: String,
        worktree: String,
        paneSessionName: String,
        socketPath: String,
        realBinaryPath: String,
        appServerPID: Int32,
        appServerProcessStartTimeMicroseconds: Int64? = nil,
        ownerPID: Int32? = nil,
        ownerProcessStartTimeMicroseconds: Int64? = nil,
        registeredAt: Date,
        agentID: String? = nil,
        threadID: String? = nil,
        activeTurnID: String? = nil
    ) {
        self.teamID = teamID
        self.worktree = worktree
        self.paneSessionName = paneSessionName
        self.socketPath = socketPath
        self.realBinaryPath = realBinaryPath
        self.appServerPID = appServerPID
        self.appServerProcessStartTimeMicroseconds = appServerProcessStartTimeMicroseconds
        self.ownerPID = ownerPID
        self.ownerProcessStartTimeMicroseconds = ownerProcessStartTimeMicroseconds
        self.registeredAt = registeredAt
        self.agentID = agentID
        self.threadID = threadID
        self.activeTurnID = activeTurnID
    }
}

public struct CodexAppServerSessionStorage: Sendable {
    private static let processLock = NSLock()

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func write(_ record: CodexAppServerSessionRecord) throws {
        try withMutationLock { try writeUnlocked(record) }
    }

    @discardableResult
    public func writeIfMatching(
        _ record: CodexAppServerSessionRecord,
        expected: CodexAppServerSessionRecord
    ) throws -> Bool {
        guard record.teamID == expected.teamID,
              record.worktree == expected.worktree,
              record.paneSessionName == expected.paneSessionName else { return false }
        return try withMutationLock {
            guard try read(teamID: expected.teamID, worktree: expected.worktree,
                           paneSessionName: expected.paneSessionName) == expected else { return false }
            try writeUnlocked(record)
            return true
        }
    }

    private func writeUnlocked(_ record: CodexAppServerSessionRecord) throws {
        let dir = appServersDirectory(teamID: record.teamID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(record)
        try data.write(to: filePath(
            teamID: record.teamID,
            worktree: record.worktree,
            paneSessionName: record.paneSessionName
        ), options: .atomic)
    }

    public func read(
        teamID: String,
        worktree: String,
        paneSessionName: String
    ) throws -> CodexAppServerSessionRecord? {
        let url = filePath(teamID: teamID, worktree: worktree, paneSessionName: paneSessionName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder().decode(CodexAppServerSessionRecord.self, from: data)
    }

    public func delete(
        teamID: String,
        worktree: String,
        paneSessionName: String
    ) throws {
        try withMutationLock {
            try deleteUnlocked(teamID: teamID, worktree: worktree, paneSessionName: paneSessionName)
        }
    }

    @discardableResult
    public func deleteIfMatching(_ record: CodexAppServerSessionRecord) throws -> Bool {
        try withMutationLock {
            guard try read(teamID: record.teamID, worktree: record.worktree,
                           paneSessionName: record.paneSessionName) == record else { return false }
            try deleteUnlocked(teamID: record.teamID, worktree: record.worktree,
                               paneSessionName: record.paneSessionName)
            return true
        }
    }

    private func deleteUnlocked(teamID: String, worktree: String, paneSessionName: String) throws {
        let url = filePath(teamID: teamID, worktree: worktree, paneSessionName: paneSessionName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func listAll() throws -> [CodexAppServerSessionRecord] {
        let fm = FileManager.default
        guard let teamDirs = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var records: [CodexAppServerSessionRecord] = []
        let decoder = Self.decoder()
        for teamDir in teamDirs {
            let appServersDir = teamDir.appendingPathComponent("codex-app-servers", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: appServersDir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let record = try? decoder.decode(CodexAppServerSessionRecord.self, from: data) {
                    records.append(record)
                }
            }
        }
        return records
    }

    public func cleanupStale(
        isAlive: (Int32) -> Bool,
        processStartTimeMicroseconds: (Int32) -> Int64?
    ) throws {
        for record in try listAll() {
            let shouldDelete: Bool
            if !isAlive(record.appServerPID) {
                shouldDelete = true
            } else if let storedStart = record.appServerProcessStartTimeMicroseconds {
                shouldDelete = storedStart != processStartTimeMicroseconds(record.appServerPID)
            } else {
                shouldDelete = false
            }
            guard shouldDelete else { continue }
            try deleteIfMatching(record)
        }
    }

    private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let path = rootDirectory.appendingPathComponent(".codex-app-server-sessions.lock").path
        let permissions = S_IRUSR | S_IWUSR
        #if canImport(Darwin)
        let fd = Darwin.open(path, O_RDWR | O_CREAT, permissions)
        #elseif canImport(Glibc)
        let fd = Glibc.open(path, O_RDWR | O_CREAT, mode_t(permissions))
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
        guard flock(fd, LOCK_EX) == 0 else { throw Self.currentPOSIXError() }
        return try body()
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func appServersDirectory(teamID: String) -> URL {
        rootDirectory
            .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
            .appendingPathComponent("codex-app-servers", isDirectory: true)
    }

    private func filePath(teamID: String, worktree: String, paneSessionName: String) -> URL {
        let leaf = TeamInbox.fileComponent("\(worktree).\(paneSessionName)") + ".json"
        return appServersDirectory(teamID: teamID).appendingPathComponent(leaf)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// @spec TEAM-10.15: When a wrapped Codex session loses its owning wrapper, the application shall stop its still-running app-server after verifying both process identities and retain its record until the server exits.
public enum CodexAppServerSessionMonitor {
    public static func cleanupOrphans(
        storage: CodexAppServerSessionStorage,
        processStartTimeMicroseconds: (Int32) -> Int64? = { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) },
        isAlive: (Int32) -> Bool = { TeamPresenceMonitor.kernelIsAlive($0) },
        terminate: ((Int32, Int64) -> Void)? = nil
    ) {
        guard let records = try? storage.listAll() else { return }
        for record in records {
            guard let ownerPID = record.ownerPID,
                  let ownerStart = record.ownerProcessStartTimeMicroseconds,
                  let serverStart = record.appServerProcessStartTimeMicroseconds
            else { continue }

            let currentOwnerStart = processStartTimeMicroseconds(ownerPID)
            if currentOwnerStart == ownerStart || (currentOwnerStart == nil && isAlive(ownerPID)) {
                continue
            }
            // A new session can replace a pane's record between the list and
            // this sweep. Never terminate its server using the old record.
            guard (try? storage.read(
                teamID: record.teamID,
                worktree: record.worktree,
                paneSessionName: record.paneSessionName
            )) == record else { continue }

            let currentServerStart = processStartTimeMicroseconds(record.appServerPID)
            if currentServerStart == serverStart {
                (terminate ?? terminateOrphan)(record.appServerPID, serverStart)
                continue
            }
            if currentServerStart == nil && isAlive(record.appServerPID) { continue }
            _ = try? storage.deleteIfMatching(record)
        }
    }

    private static func terminateOrphan(pid: Int32, start: Int64) {
        guard ProcessIdentityReader.startTimeMicroseconds(ofPID: pid) == start else { return }
        _ = kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard ProcessIdentityReader.startTimeMicroseconds(ofPID: pid) == start else { return }
            _ = kill(pid, SIGKILL)
        }
    }
}
