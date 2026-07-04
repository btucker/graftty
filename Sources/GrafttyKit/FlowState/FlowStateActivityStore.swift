import Foundation

public struct FlowStateActivity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case publishError
        case publishAccepted
        case statusRequestSent
        case statusRequestSkipped
        case actionRequiresConfirmation
        case actionExecuted
        case actionSkipped
    }

    public let createdAt: Date
    public let kind: Kind
    public let message: String
    public let worktreeRef: String?

    public init(createdAt: Date, kind: Kind, message: String, worktreeRef: String?) {
        self.createdAt = createdAt
        self.kind = kind
        self.message = message
        self.worktreeRef = worktreeRef
    }
}

public final class FlowStateActivityStore: @unchecked Sendable {
    private static let recentReadChunkSize = 64 * 1024

    private let rootDirectory: URL
    private let lock = NSLock()

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func defaultRoot() -> URL {
        AppState.defaultDirectory.appendingPathComponent("flow-state", isDirectory: true)
    }

    public static func defaultStore() -> FlowStateActivityStore {
        FlowStateActivityStore(rootDirectory: defaultRoot())
    }

    public func append(_ activity: FlowStateActivity) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try Self.jsonlEncoder.encode(activity)
        let line = data + Data([0x0A])
        if FileManager.default.fileExists(atPath: activityURL.path) {
            let handle = try FileHandle(forWritingTo: activityURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: activityURL, options: .atomic)
        }
    }

    public func recent(limit: Int) throws -> [FlowStateActivity] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0, FileManager.default.fileExists(atPath: activityURL.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: activityURL)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        var buffer = Data()

        while true {
            let rows = Self.decodeRows(from: buffer, startsAtFileBeginning: offset == 0)
            if rows.count >= limit || offset == 0 {
                return Array(rows.suffix(limit).reversed())
            }

            let readSize = min(Self.recentReadChunkSize, Int(offset))
            guard readSize > 0 else { return [] }
            offset -= UInt64(readSize)
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: readSize) ?? Data()
            buffer = chunk + buffer
        }
    }

    public func recordStatusRequest(worktreeRef: String, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        var cooldowns = try readCooldowns()
        cooldowns[worktreeRef] = date
        try writeCooldowns(cooldowns)
    }

    public func lastStatusRequestAt(worktreeRef: String) throws -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return try readCooldowns()[worktreeRef]
    }

    private var activityURL: URL {
        rootDirectory.appendingPathComponent("activity.jsonl", isDirectory: false)
    }

    private var cooldownsURL: URL {
        rootDirectory.appendingPathComponent("status-request-cooldowns.json", isDirectory: false)
    }

    private static var jsonlEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decodeRows(from data: Data, startsAtFileBeginning: Bool) -> [FlowStateActivity] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let completeLines = startsAtFileBeginning ? lines[...] : lines.dropFirst()
        return completeLines.compactMap { line in
            try? JSONDecoder.flowState.decode(FlowStateActivity.self, from: Data(line.utf8))
        }
    }

    private func readCooldowns() throws -> [String: Date] {
        guard FileManager.default.fileExists(atPath: cooldownsURL.path) else { return [:] }
        let data = try Data(contentsOf: cooldownsURL)
        return try JSONDecoder.flowState.decode([String: Date].self, from: data)
    }

    private func writeCooldowns(_ cooldowns: [String: Date]) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.flowState.encode(cooldowns)
        try data.write(to: cooldownsURL, options: .atomic)
    }
}
