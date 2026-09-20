import ArgumentParser
import Foundation
import GrafttyKit

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a file or host-tunneled URL in GrafttyMobile"
    )

    @Argument(help: "File up to 20 MB, or an http:// or https:// URL. HTML files include only that file.")
    var target: String

    func run() throws {
        let resource = try OpenResourceTarget.resolve(target)
        let path = resource.isFileURL ? resource.path : resource.absoluteString
        let worktree = try CLIEnv.resolveWorktree()
        try CLIEnv.expectOk(CLIEnv.sendRequest(.offerResource(path: worktree, target: path)))
        print("Resource offered to GrafttyMobile for 15 minutes. Open this worktree on mobile to preview it.")
    }
}
