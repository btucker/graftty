import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct RemoteSetupLinux: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-linux",
        abstract: "Install and pair a remote runner on Linux from this Mac",
        discussion: """
        Requires Graftty running on this Mac and an SSH destination already trusted
        and accessible with keys or ssh-agent. Installs missing Claude Code and
        Codex commands; sign in to providers on Linux separately.
        Projects transfer committed history only, including unpushed commits.
        The default branch is each repository's current branch.

        To add a runner that is already running, such as a container, pass the
        line printed by graftty-runner invite instead of an SSH destination.

        Examples:
          graftty remote setup-linux user@host --version 1.2.3 --project ~/projects/app
          graftty remote setup-linux host-alias --archive ./graftty-linux.tar.gz
          graftty remote add-runner 'graftty-invite-1:…'
        """,
        aliases: ["add-runner"])
    @Argument(help: "SSH alias, user@host, or a runner invite") var destination: String
    @Option(help: "Published Linux archive version") var version: String?
    @Option(help: "Local Linux development archive") var archive: String?
    @Option(name: .customLong("project"), help: "Local repository to import; repeat for multiple repositories") var projects: [String] = []
    @Option(help: "Branch to check out for each imported project; defaults to its current branch") var branch: String?
    @Option(help: "Linux project directory") var projectRoot = "~/projects"
    @Flag(help: "Print the installed host result as JSON; progress goes to stderr") var json = false

    /// The runner invite given in place of an SSH destination, if any.
    var invite: RunnerInvite? { try? RunnerInvite(parsing: destination) }

    func validate() throws {
        if RunnerInvite.looksLikeInvite(destination) {
            do { _ = try RunnerInvite(parsing: destination) }
            catch { throw ValidationError(error.localizedDescription) }
            guard version == nil, archive == nil, projects.isEmpty, branch == nil else {
                throw ValidationError("An invite adds a running runner; --version, --archive, --project, and --branch apply only to SSH setup.")
            }
            return
        }
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
                                  projects: selected, archive: source, client: client,
                                  agentTools: [.claude, .codex], requireAgentTools: true)
    }

    func run() async throws {
        #if os(macOS)
        if let invite {
            do { try await withCLIInterruptCancellation { try await redeem(invite) } }
            catch is CancellationError { throw ExitCode(130) }
            if json {
                print(#"{"connectionRequested":true}"#)
            } else {
                print("Added \(invite.identity.displayName). Connection requested in Graftty; check the Remote Hosts sidebar for status.")
            }
            return
        }
        do {
            let result = try await withCLIInterruptCancellation { try await provision() }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(SetupOutput(host: result, connectionRequested: true)), as: UTF8.self))
            } else {
                print("Installed and paired \(result.identity.displayName). Connection requested in Graftty; check the Remote Hosts sidebar for status.")
            }
        } catch is CancellationError { throw ExitCode(130) }
        catch let error as LinuxHostSetupError { throw ValidationError(error.localizedDescription) }
        #else
        throw ValidationError("Run setup-linux on the Mac that will connect to the runner, with Graftty running.")
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
        let result = try await LinuxHostSetup().run(plan: plan, progress: { step in
            FileHandle.standardError.write(Data("[\(step.completed + 1)/\(step.total)] \(step.message)\n".utf8))
        })
        try Task.checkCancellation()
        try CLIEnv.expectOk(CLIEnv.sendRequest(.completeLinuxSetup(result)), for: "remote setup-linux")
        return result
    }

    #if os(macOS)
    /// Enrolls this Mac's key over Tailcat, then asks the app to save the
    /// runner. The invite's secret never leaves this process.
    private func redeem(_ invite: RunnerInvite) async throws {
        guard invite.expiresAt > Date() else {
            throw ValidationError("This invite has expired. Run graftty-runner invite on the runner and use the new line.")
        }
        let client: LinuxHostTrustRequest
        switch try CLIEnv.sendRequest(.linuxSetupIdentity) {
        case .linuxSetupIdentity(let identity): client = identity
        case .error(let message): throw ValidationError(message)
        default: throw ValidationError("The running Graftty app does not support runner invites. Update and relaunch it, then retry.")
        }
        guard let key = try ClientIdentityStore(directory: ClientIdentityStore.defaultDirectory).load(),
              key.publicKey.rawRepresentation.base64EncodedString() == client.publicKey,
              let hostKeyData = Data(base64Encoded: invite.identity.publicKey) else {
            throw ValidationError("This Mac's Graftty identity is missing or changed. Relaunch Graftty, then retry.")
        }
        let token = RunnerEnrollmentToken(secret: invite.secret, deviceID: client.deviceID, displayName: client.displayName)
        FileHandle.standardError.write(Data("Connecting to \(invite.identity.displayName) over Tailcat…\n".utf8))
        do {
            try await RunnerInviteEnrollment.enroll(hostPublicKey: RemoteIdentityPublicKey(rawRepresentation: hostKeyData),
                                                    enrollmentUsername: token.username, clientKey: key, endpoint: invite.endpoint)
        } catch is CancellationError { throw CancellationError() }
        catch PinnedHostKeyError.hostKeyMismatch {
            throw ValidationError("The runner's identity does not match this invite. Nothing was saved.")
        } catch DirectSSHHostConnection.ConnectionError.authenticationRejected {
            throw ValidationError("The runner refused this invite. It may have been used already, expired, or the runner restarted. Run graftty-runner invite again.")
        } catch {
            throw ValidationError("Could not reach the runner over Tailcat. Check that it is running and has outbound internet access, then retry.")
        }
        try CLIEnv.expectOk(CLIEnv.sendRequest(.addInvitedRunner(identity: invite.identity, endpoint: invite.endpoint)),
                            for: "remote add-runner")
    }
    #endif

    private struct SetupOutput: Encodable {
        let host: LinuxHostSetupResult
        let connectionRequested: Bool
    }
}
