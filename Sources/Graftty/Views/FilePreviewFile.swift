import Foundation
import GrafttyKit

/// Owns an immutable local copy until the last tray using it is released.
final class FilePreviewFile {
    let url: URL
    let sourceURL: URL?
    private let directory: URL

    init(_ snapshot: FilePreviewLoader.Snapshot, sourceURL: URL? = nil) throws {
        self.sourceURL = sourceURL
        guard !snapshot.filename.isEmpty, snapshot.filename != ".", snapshot.filename != "..",
              !snapshot.filename.contains("/"), !snapshot.filename.contains("\0") else {
            throw FilePreviewLoader.Failure.unreadable
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-preview-" + UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent(snapshot.filename)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do { try snapshot.bytes.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
