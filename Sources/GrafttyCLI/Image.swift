import ArgumentParser
import Foundation
import GrafttyKit

/// Requests a native preview on the pane leader without terminal drawing.
struct Image: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview an image in the native tray on the device leading this pane")
    @Argument(help: "Path to a PNG, JPEG, HEIC, GIF, WebP, or PDF file, up to 20 MB.")
    var path: String
    @Option(name: .long, help: "Legacy option, accepted but ignored by the native preview.")
    var width: Int?
    @Option(name: .long, help: "Legacy option, accepted but ignored by the native preview.")
    var pad: Int = 12

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let worktree = try Open.worktreePath(environment: environment, resolve: CLIEnv.resolveWorktree)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        try CLIEnv.expectOk(CLIEnv.sendRequest(.previewImage(
            path: worktree, target: url.path, paneSessionName: environment["ZMX_SESSION"]
        )))
        // Acknowledges a preview request, not that the user viewed it.
    }
}
