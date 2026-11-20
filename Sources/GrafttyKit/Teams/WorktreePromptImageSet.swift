import Foundation
import GrafttyProtocol

/// Host-local files used by the initial launch and any retry of that launch.
/// Persist only their identity in state, and omit it from viewer summaries.
struct WorktreePromptImageSet: Codable, Equatable, Sendable {
    let id: UUID
    let count: Int

    enum StagingError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    static func validationError(_ images: [Data]) -> String? {
        if let error = WorktreeAgentConfiguration.promptImageSizeError(images) { return error }
        guard images.allSatisfy(isBoundedPNG) else {
            return "Prompt attachments must be valid PNG images."
        }
        return nil
    }

    static func stage(_ images: [Data], in promptDirectory: URL) throws -> Self {
        if let error = validationError(images) { throw StagingError.invalid(error) }
        let set = Self(id: UUID(), count: images.count)
        let directory = set.directory(in: promptDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        do {
            for (file, data) in zip(set.files(in: promptDirectory), images) {
                guard manager.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        } catch {
            set.discard(in: promptDirectory)
            throw error
        }
        return set
    }

    func files(in promptDirectory: URL) -> [URL] {
        guard (1...WorktreeAgentConfiguration.maximumPromptImageCount).contains(count) else { return [] }
        let directory = directory(in: promptDirectory)
        return (1...count).map { directory.appendingPathComponent("image-\($0).png") }
    }

    func discard(in promptDirectory: URL) {
        try? FileManager.default.removeItem(at: directory(in: promptDirectory))
    }

    private func directory(in promptDirectory: URL) -> URL {
        promptDirectory.appendingPathComponent(id.uuidString + ".images", isDirectory: true)
    }

    static func pruneUnreferenced(in promptDirectory: URL, state: AppState) {
        let retained = Set(state.repos.flatMap(\.worktrees).flatMap(\.agents).compactMap { $0.promptImageSet?.id })
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let directories = try? manager.contentsOfDirectory(at: promptDirectory, includingPropertiesForKeys: Array(keys)) else { return }
        for directory in directories where directory.pathExtension == "images" {
            guard let id = UUID(uuidString: directory.deletingPathExtension().lastPathComponent),
                  !retained.contains(id),
                  let modified = try? directory.resourceValues(forKeys: keys).contentModificationDate,
                  modified < cutoff else { continue }
            try? manager.removeItem(at: directory)
        }
    }

    private static func isBoundedPNG(_ data: Data) -> Bool {
        let header = Array(data.prefix(24))
        guard header.count == 24,
              header.prefix(16).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]),
              data.suffix(12).elementsEqual([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]) else { return false }
        let width = header[16..<20].reduce(0) { ($0 << 8) | Int($1) }
        let height = header[20..<24].reduce(0) { ($0 << 8) | Int($1) }
        return (1...4096).contains(width) && (1...4096).contains(height)
    }
}
