import AppKit

@MainActor
enum ImagePreviewExternalOpen {
    struct Request: Equatable {
        let file: URL
        let application: URL
    }
    enum Failure: LocalizedError {
        case fileUnavailable, applicationUnavailable
        var errorDescription: String? {
            switch self {
            case .fileUnavailable: "This image file is no longer available. Run graftty image again."
            case .applicationUnavailable: "Preview.app is not available on this Mac."
            }
        }
    }

    static func request(file: URL, applicationLookup: (String) -> URL?) throws -> Request {
        guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path),
              (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw Failure.fileUnavailable
        }
        guard let application = applicationLookup("com.apple.Preview") else { throw Failure.applicationUnavailable }
        return Request(file: file, application: application)
    }

    static func open(_ file: URL) async throws {
        let workspace = NSWorkspace.shared
        let request = try request(file: file, applicationLookup: workspace.urlForApplication(withBundleIdentifier:))
        _ = try await workspace.open([request.file], withApplicationAt: request.application,
                                     configuration: NSWorkspace.OpenConfiguration())
    }
}
