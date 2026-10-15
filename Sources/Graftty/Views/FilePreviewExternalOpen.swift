import AppKit

@MainActor
enum FilePreviewExternalOpen {
    enum Failure: LocalizedError {
        case unavailable, noApplication
        var errorDescription: String? {
            switch self {
            case .unavailable: "This file is no longer available. Run graftty preview again."
            case .noApplication: "No application is available to open this file."
            }
        }
    }
    static func open(_ file: URL) async throws {
        guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path),
              (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { throw Failure.unavailable }
        let workspace = NSWorkspace.shared
        guard let application = workspace.urlForApplication(toOpen: file) else { throw Failure.noApplication }
        _ = try await workspace.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
}
