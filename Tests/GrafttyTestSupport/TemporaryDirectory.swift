import Foundation

/// Creates a uniquely named directory under the system temporary directory
/// and returns its URL. The caller owns cleanup.
public func makeTempDir(prefix: String = "graftty") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
