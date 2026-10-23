import ArgumentParser
import Foundation
import GrafttyKit

/// Requests a native preview on the pane leader without terminal drawing.
struct Image: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preview", abstract: "Preview files with Quick Look on the device leading this pane", aliases: ["image"])
    @Argument(help: "Local files supported by Quick Look. Up to 20 files, 20 MB per file and 50 MB total.")
    var paths: [String]
    @Option(name: .long, help: "Legacy option, accepted but ignored by the native preview.")
    var width: Int?
    @Option(name: .long, help: "Legacy option, accepted but ignored by the native preview.")
    var pad: Int = 12

    func validate() throws {
        guard (1...FilePreviewLoader.maximumFiles).contains(paths.count) else {
            throw ValidationError("Choose between 1 and 20 files to preview.")
        }
    }

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let worktree = try Open.worktreePath(environment: environment, resolve: CLIEnv.resolveWorktree)
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        try CLIEnv.expectOk(CLIEnv.sendRequest(.previewFiles(
            path: worktree, targets: urls.map(\.path), paneSessionName: environment["ZMX_SESSION"]
        )), for: "preview")
        // Acknowledges a preview request, not that the user viewed it.
    }
}
