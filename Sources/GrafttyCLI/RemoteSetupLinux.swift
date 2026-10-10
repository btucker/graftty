import ArgumentParser
import Foundation
import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct RemoteSetupLinux: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-linux",
        abstract: "Install and pair a Linux host from this Mac",
        discussion: """
        Requires Graftty running on this Mac and an SSH destination already trusted
        and accessible with keys or ssh-agent. Installs missing Claude Code and
        Codex commands; sign in to providers on Linux separately.
        Projects transfer committed history only, including unpushed commits.
        The default branch is each repository's current branch.

        Examples:
          graftty remote setup-linux user@host --version 1.2.3 --project ~/projects/app
          graftty remote setup-linux host-alias --archive ./graftty-linux.tar.gz
        """)
    @Argument(help: "SSH alias or user@host") var destination: String
    @Option(help: "Published Linux archive version") var version: String?
    @Option(help: "Local Linux development archive") var archive: String?
    @Option(name: .customLong("project"), help: "Local repository to import; repeat for multiple repositories") var projects: [String] = []
    @Option(help: "Branch to check out for each imported project; defaults to its current branch") var branch: String?
    @Option(help: "Linux project directory") var projectRoot = "~/projects"
    @Flag(help: "Print the installed host result as JSON; progress goes to stderr") var json = false

    func validate() throws {
        _ = try LinuxHostDestination(destination)
        guard (version == nil) != (archive == nil) else {
            throw ValidationError("Specify exactly one of --version or --archive.")
        }
        if branch != nil && projects.isEmpty { throw ValidationError("--branch requires --project.") }
    }

    func makePlan(client: LinuxHostTrustRequest, executor: any CLIExecutor = CLIRunner()) async throws -> LinuxHostSetupPlan {
        try Task.checkCancellation()
        var selected: [LinuxHostProject] = []
        for path in projects {
            try Task.checkCancellation()
            let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            let root = try await executor.run(command: "git", args: ["rev-parse", "--show-toplevel"], at: directory, timeout: .seconds(15))
                .stdout.trimmingCharacters(in: .newlines)
            try Task.checkCancellation()
            let selectedBranch: String
            if let branch { selectedBranch = branch }
            else {
                let output = try await executor.capture(command: "git", args: ["symbolic-ref", "--quiet", "--short", "HEAD"], at: root, timeout: .seconds(15))
                try Task.checkCancellation()
                guard output.exitCode == 0 else {
                    throw ValidationError("\(path) has no current branch. Select a committed local branch with --branch.")
                }
                selectedBranch = output.stdout.trimmingCharacters(in: .newlines)
            }
            selected.append(.init(localPath: root, branch: selectedBranch,
                                  directoryName: URL(fileURLWithPath: root).lastPathComponent))
        }
        try LinuxHostSetup.validateProjects(selected, destinationRoot: projectRoot)
        let source: LinuxHostArchive
        if let archive {
            source = .local(URL(fileURLWithPath: (archive as NSString).expandingTildeInPath).standardizedFileURL)
        } else if let version { source = .release(version: version) }
        else { throw ValidationError("Specify --version or --archive.") }
        return LinuxHostSetupPlan(destination: try .init(destination), destinationRoot: projectRoot,
                                  projects: selected, archive: source, client: client)
    }

    func run() async throws {
        #if os(macOS)
        let operation = Task { try await provision() }
        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousTerminate = signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { operation.cancel() }
            source.resume()
            return source
        }
        defer {
            signals.forEach { $0.cancel() }
            signal(SIGINT, previousInterrupt)
            signal(SIGTERM, previousTerminate)
        }
        do {
            let result = try await operation.value
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(SetupOutput(host: result, connectionRequested: true)), as: UTF8.self))
            } else {
                print("Installed and paired \(result.identity.displayName). Connection requested in Graftty; check the Remote Macs sidebar for status.")
            }
        } catch is CancellationError { throw ExitCode(130) }
        catch let error as LinuxHostSetupError { throw ValidationError(error.localizedDescription) }
        #else
        throw ValidationError("Run setup-linux on the Mac that will connect to the Linux host, with Graftty running.")
        #endif
    }

    private func provision() async throws -> LinuxHostSetupResult {
        try Task.checkCancellation()
        let response = try CLIEnv.sendRequest(.linuxSetupIdentity)
        try Task.checkCancellation()
        let client: LinuxHostTrustRequest
        switch response {
        case .linuxSetupIdentity(let identity): client = identity
        case .error(let message): throw ValidationError(message)
        default: throw ValidationError("The running Graftty app does not support Linux CLI setup. Update and relaunch it, then retry.")
        }
        let plan = try await makePlan(client: client)
        let result = try await LinuxHostSetup().run(plan: plan) { step in
            FileHandle.standardError.write(Data("[\(step.completed + 1)/\(step.total)] \(step.message)\n".utf8))
        }
        try Task.checkCancellation()
        try CLIEnv.expectOk(CLIEnv.sendRequest(.completeLinuxSetup(result)))
        return result
    }

    private struct SetupOutput: Encodable {
        let host: LinuxHostSetupResult
        let connectionRequested: Bool
    }
}
