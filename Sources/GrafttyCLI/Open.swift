import ArgumentParser
import Foundation
import GrafttyKit

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a file or URL on the device leading this pane"
    )

    @Argument(help: "File path or HTTP(S) URL. Mobile file previews are limited to 20 MB; HTML includes only that file.")
    var target: String

    func run() throws {
        let resource = try OpenResourceTarget.resolve(target)
        let path = resource.isFileURL ? resource.path : resource.absoluteString
        let worktree = try CLIEnv.resolveWorktree()
        try CLIEnv.expectOk(CLIEnv.sendRequest(Self.request(
            path: worktree, target: path, environment: ProcessInfo.processInfo.environment
        )))
        print("Resource routed for review.")
    }

    static func request(path: String, target: String, environment: [String: String]) -> NotificationMessage {
        .offerResource(path: path, target: target, paneSessionName: environment["ZMX_SESSION"])
    }
}
