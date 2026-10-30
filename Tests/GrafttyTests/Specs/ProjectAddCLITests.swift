import ArgumentParser
import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit

struct ProjectAddCLITests {
    @Test("@spec PROJECT-1.9: When graftty project add receives a relative path, the CLI shall resolve it against the caller working directory and register it through the running app without requiring a tracked caller worktree.")
    func relativePathAndProtocol() throws {
        let command = try #require(GrafttyCLI.parseAsRoot(["project", "add", "../project"]) as? ProjectAdd)
        var sent: [NotificationMessage] = []
        var output: [String] = []
        try ProjectAddCommand.run(path: command.path, workingDirectory: "/projects/caller", send: {
            sent.append($0)
            return $0 == .capabilities ? .capabilities(["project_add"]) : .ok
        }, writeLine: { output.append($0) })
        #expect(sent == [.capabilities, .addProject(path: "/projects/project")])
        #expect(output.count == 1)
        let request = try #require(sent.last)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: data) == request)
        #expect(request.expectsResponse)
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["project", "add"]) }
    }

    @Test("@spec PROJECT-1.10: If the running app is unavailable or does not support project registration, then graftty project add shall fail before sending an addition and explain how to start or update the app.")
    func unsupportedAndUnavailableApp() throws {
        for response: ResponseMessage in [.capabilities([]), .error("unsupported")] {
            var sent: [NotificationMessage] = []
            #expect(throws: (any Error).self) {
                try ProjectAddCommand.run(path: "/project", send: { sent.append($0); return response }, writeLine: { _ in })
            }
            #expect(!sent.contains(.addProject(path: "/project")))
        }
        var sent: [NotificationMessage] = []
        #expect(throws: (any Error).self) {
            try ProjectAddCommand.run(path: "/project", send: { sent.append($0); throw CLIError.appNotRunning }, writeLine: { _ in })
        }
        #expect(sent == [.capabilities])
    }
}
