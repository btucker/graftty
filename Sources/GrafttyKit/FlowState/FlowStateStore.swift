import Foundation
import CryptoKit

public final class FlowStateStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let lock = NSLock()

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func defaultRoot() -> URL {
        AppState.defaultDirectory.appendingPathComponent("flow-state", isDirectory: true)
    }

    public static func defaultStore() -> FlowStateStore {
        FlowStateStore(rootDirectory: defaultRoot())
    }

    public func recommendation() throws -> FlowRecommendationEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return try readIfPresent(FlowRecommendationEnvelope.self, from: recommendationURL)
    }

    public func writeRecommendation(_ envelope: FlowRecommendationEnvelope) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(envelope, to: recommendationURL)
    }

    public func summaries() throws -> [String: FlowWorktreeSummary] {
        lock.lock()
        defer { lock.unlock() }
        return try readCollection(FlowWorktreeSummary.self, from: summariesDirectory)
    }

    public func writeSummary(_ summary: FlowWorktreeSummary) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(summary, to: fileURL(in: summariesDirectory, worktreeRef: summary.worktreeRef))
    }

    public func notes() throws -> [String: FlowWorktreeNote] {
        lock.lock()
        defer { lock.unlock() }
        return try readCollection(FlowWorktreeNote.self, from: notesDirectory)
    }

    public func writeNote(_ note: FlowWorktreeNote) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(note, to: fileURL(in: notesDirectory, worktreeRef: note.worktreeRef))
    }

    public func snoozes() throws -> [String: FlowSnooze] {
        lock.lock()
        defer { lock.unlock() }
        return try readCollection(FlowSnooze.self, from: snoozesDirectory)
    }

    public func writeSnooze(_ snooze: FlowSnooze) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(snooze, to: fileURL(in: snoozesDirectory, worktreeRef: snooze.worktreeRef))
    }

    private var recommendationURL: URL {
        rootDirectory.appendingPathComponent("latest-recommendation.json", isDirectory: false)
    }

    private var summariesDirectory: URL {
        rootDirectory.appendingPathComponent("summaries", isDirectory: true)
    }

    private var notesDirectory: URL {
        rootDirectory.appendingPathComponent("notes", isDirectory: true)
    }

    private var snoozesDirectory: URL {
        rootDirectory.appendingPathComponent("snoozes", isDirectory: true)
    }

    private func fileURL(in directory: URL, worktreeRef: String) -> URL {
        directory.appendingPathComponent("\(Self.safeFileName(for: worktreeRef)).json", isDirectory: false)
    }

    private func readIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.flowState.decode(type, from: data)
    }

    private func readCollection<T: Decodable & FlowWorktreeRefBacked>(
        _ type: T.Type,
        from directory: URL
    ) throws -> [String: T] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [:] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var values: [String: T] = [:]
        for url in urls where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder.flowState.decode(type, from: data)
            values[value.worktreeRef] = value
        }
        return values
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.flowState.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func safeFileName(for worktreeRef: String) -> String {
        let digest = SHA256.hash(data: Data(worktreeRef.utf8))
        return "sha256-\(digest.map { String(format: "%02x", $0) }.joined())"
    }
}

private protocol FlowWorktreeRefBacked {
    var worktreeRef: String { get }
}

extension FlowWorktreeSummary: FlowWorktreeRefBacked {}
extension FlowWorktreeNote: FlowWorktreeRefBacked {}
extension FlowSnooze: FlowWorktreeRefBacked {}
