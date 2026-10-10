import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit

struct RemoteSetupLinuxCLITests {
    @Test("@spec REMOTE-21.22: When graftty remote setup-linux runs, the CLI shall require an explicit release or archive, resolve selected repositories and branches, and reuse Linux setup with the running Mac app's public identity.")
    func parsesAndResolvesProjectPlan() async throws {
        let command = try #require(GrafttyCLI.parseAsRoot([
            "remote", "setup-linux", "developer@host", "--version", "1.2.3",
            "--project", "/tmp/repo", "--project-root", "~/code", "--json"
        ]) as? RemoteSetupLinux)
        let client = LinuxHostTrustRequest(deviceID: "mac", displayName: "Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString())
        let plan = try await command.makePlan(client: client, executor: SetupProjectExecutor())
        #expect(plan.client == client)
        #expect(plan.destination.value == "developer@host")
        #expect(plan.destinationRoot == "~/code")
        #expect(plan.archive == .release(version: "1.2.3"))
        #expect(plan.projects == [.init(localPath: "/canonical/project", branch: "feature", directoryName: "project")])
        #expect(command.json)
    }

    @Test(arguments: [[], ["--version", "1.2.3", "--archive", "/tmp/archive"], ["--version", "1.2.3", "--branch", "feature"]])
    func rejectsAmbiguousOptions(options: [String]) {
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["remote", "setup-linux", "host"] + options) }
    }

    @Test("@spec REMOTE-21.25: When CLI Linux setup is cancelled while resolving a project, the application shall stop before subsequent Git probes or remote setup commands.")
    func cancellationStopsProjectProbes() async throws {
        let command = try #require(GrafttyCLI.parseAsRoot(["remote", "setup-linux", "host", "--version", "1.2.3", "--project", "/tmp/repo"]) as? RemoteSetupLinux)
        let task = Task {
            try await command.makePlan(client: .init(deviceID: "mac", displayName: "Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString()), executor: SetupProjectExecutor(cancelAfterRoot: true))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func explicitBranchAndArchive() async throws {
        let command = try #require(GrafttyCLI.parseAsRoot(["remote", "setup-linux", "host", "--archive", "./archive.tar.gz", "--project", "/tmp/repo", "--branch", "other"]) as? RemoteSetupLinux)
        let plan = try await command.makePlan(client: .init(deviceID: "mac", displayName: "Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString()), executor: SetupProjectExecutor())
        #expect(plan.projects.first?.branch == "other")
        guard case .local(let archive) = plan.archive else { Issue.record("Expected local archive"); return }
        #expect(archive.isFileURL)
        #expect(archive.path.hasSuffix("/archive.tar.gz"))
    }
}

private struct SetupProjectExecutor: CLIExecutor {
    var cancelAfterRoot = false
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        #expect(command == "git")
        switch args {
        case ["rev-parse", "--show-toplevel"]:
            if cancelAfterRoot { withUnsafeCurrentTask { $0?.cancel() } }
            return .init(stdout: "/canonical/project\n", stderr: "", exitCode: 0)
        case ["symbolic-ref", "--quiet", "--short", "HEAD"]:
            #expect(!cancelAfterRoot)
            return .init(stdout: "feature\n", stderr: "", exitCode: 0)
        default: Issue.record("Unexpected Git command: \(args)"); return .init(stdout: "", stderr: "", exitCode: 1)
        }
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput { try await run(command: command, args: args, at: directory) }
}
