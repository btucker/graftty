import Foundation

public struct CodexAppServerSessionRecord: Codable, Equatable, Sendable {
    public let teamID: String
    public let worktree: String
    public let paneSessionName: String
    public let socketPath: String
    public let realBinaryPath: String
    public let appServerPID: Int32
    public let appServerProcessStartTimeMicroseconds: Int64?
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
        self.registeredAt = registeredAt
        self.agentID = agentID
        self.threadID = threadID
        self.activeTurnID = activeTurnID
    }
}

public struct CodexAppServerSessionStorage: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func write(_ record: CodexAppServerSessionRecord) throws {
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
            try delete(
                teamID: record.teamID,
                worktree: record.worktree,
                paneSessionName: record.paneSessionName
            )
        }
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
