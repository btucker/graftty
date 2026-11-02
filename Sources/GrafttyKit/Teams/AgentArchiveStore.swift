import Foundation
import GrafttyProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Host-local, immutable archive identity. AppState retains no transcript bytes.
public struct AgentTranscriptArchive: Codable, Sendable, Equatable {
    public let id: String
    public let byteCount: Int
    public init(id: String, byteCount: Int) { self.id = id; self.byteCount = byteCount }
}

public struct AgentArchiveStore: Sendable {
    public let directory: URL
    public init(directory: URL = AppState.defaultDirectory.appendingPathComponent("agent-launch-prompts/archives", isDirectory: true)) {
        self.directory = directory
    }

    public func write(_ transcript: String) throws -> AgentTranscriptArchive {
        try AttentionFileHandoff(rootDirectory: directory).ensureDirectory()
        let data = Data(transcript.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reference = AgentTranscriptArchive(id: digest, byteCount: data.count)
        // Retrying failed cleanup or state persistence must not duplicate a large archive.
        if FileManager.default.fileExists(atPath: url(reference).path) {
            try validate(reference)
            return reference
        }
        try data.write(to: url(reference), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(reference).path)
        return reference
    }

    public func read(_ reference: AgentTranscriptArchive) throws -> String {
        try validate(reference)
        return try String(contentsOf: url(reference), encoding: .utf8)
    }

    /// UI previews stay bounded; the CLI retrieves the complete archive in chunks.
    public func preview(_ reference: AgentTranscriptArchive, agentID: String, maximumBytes: Int = 256 * 1024) throws -> String {
        try validate(reference)
        let handle = try FileHandle(forReadingFrom: url(reference))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: max(0, maximumBytes)) ?? Data()
        // Drop an incomplete trailing UTF-8 scalar rather than displaying replacement glyphs.
        var bytes = data
        for _ in 0..<3 where String(data: bytes, encoding: .utf8) == nil { bytes = bytes.dropLast() }
        guard let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return data.count < reference.byteCount
            ? text + "\n\n[Preview only. Full transcript: graftty agent show \(agentID) --json]" : text
    }

    public func preview(_ agent: ManagedAgent) throws -> String? {
        if let reference = agent.transcriptArchive { return try preview(reference, agentID: agent.id) }
        guard let transcript = agent.transcript else { return nil }
        let text = AgentTextPreview.prefix(transcript, bytes: 256 * 1024)
        return text.utf8.count < transcript.utf8.count
            ? text + "\n\n[Preview only. Full transcript: graftty agent show \(agent.id) --json]" : text
    }

    /// Detail snapshots are disposable; durable transcript files are never pruned here.
    public func removeExpiredDetails(excluding activeFiles: Set<URL> = []) throws {
        let details = directory.appendingPathComponent("details", isDirectory: true)
        guard FileManager.default.fileExists(atPath: details.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: details, includingPropertiesForKeys: [.contentModificationDateKey]) {
            guard !activeFiles.contains(file), file.pathExtension == "json",
                  let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) >= 60 else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    private func url(_ reference: AgentTranscriptArchive) -> URL {
        directory.appendingPathComponent(reference.id + ".txt")
    }

    private func validate(_ reference: AgentTranscriptArchive) throws {
        guard reference.id.utf8.count == 64,
              reference.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let values = try url(reference).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == reference.byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
