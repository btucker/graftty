import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit

struct OpenCLITests {
    @Test("@spec IOS-12.3: When the user runs graftty open with a file path, the CLI shall offer that file for native preview in the caller's tracked worktree and report request failures.")
    func parsesFileArgumentAndEncodesRequest() throws {
        let command = try Open.parse(["./report with spaces.html"])
        #expect(command.target == "./report with spaces.html")
        #expect(throws: (any Error).self) { try Open.parse([]) }
        let message = NotificationMessage.offerResource(path: "/project", target: "/tmp/report.html")
        #expect(message.expectsResponse)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(message)) == message)
    }
}
