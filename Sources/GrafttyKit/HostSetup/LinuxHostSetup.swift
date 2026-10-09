import CryptoKit
import Foundation

public struct LinuxHostSetup: Sendable {
    private let executor: any CLIExecutor
    private let ssh: any LinuxHostSSHExecuting

    public init(executor: (any CLIExecutor)? = nil, ssh: any LinuxHostSSHExecuting = LinuxHostSSHRunner()) {
        self.executor = executor ?? LinuxHostSetupLocalRunner()
        self.ssh = ssh
    }

    public func run(
        plan: LinuxHostSetupPlan,
        progress: @escaping @Sendable (LinuxHostSetupProgress) async -> Void = { _ in }
    ) async throws -> LinuxHostSetupResult {
        try plan.client.validate()
        try Self.validateProjects(plan.projects, destinationRoot: plan.destinationRoot)
        let version: String?
        switch plan.archive {
        case .release(let value):
            guard Self.validVersion(value) else { throw LinuxHostSetupError.invalidPlan("Enter a published release version, such as 1.2.3 or 1.2.3-beta.1.") }
            version = value
        case .local(let file):
            guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else {
                throw LinuxHostSetupError.invalidPlan("Choose a readable local Linux release archive.")
            }
            version = nil
        }
        let total = 4 + plan.projects.count * 2
        await progress(.init(message: "Checking SSH destination and Ubuntu dependencies", completed: 0, total: total))
        try Task.checkCancellation()
        let config = try await executor.run(command: "/usr/bin/ssh", args: ["-G", "--", plan.destination.value], at: NSHomeDirectory(), timeout: .seconds(15))
        let resolved = try LinuxHostResolvedSSH.parse(config.stdout)
        let platform = try LinuxHostPlatform.parse(try await remote(plan.destination, command: LinuxHostScripts.detect).stdout)
        let root = plan.destinationRoot.hasPrefix("~/")
            ? platform.homeDirectory + String(plan.destinationRoot.dropFirst()) : plan.destinationRoot
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-linux-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: local) }
        // Validate and snapshot every project before modifying the Linux host.
        // Existing remote project registrations are harmless on a retry.
        var snapshots: [LinuxHostRepositorySnapshot] = []
        for (index, project) in plan.projects.enumerated() {
            await progress(.init(message: "Preparing committed history for \(project.directoryName)", completed: 1, total: total))
            snapshots.append(try await Self.prepareBundle(project: project, output: local.appendingPathComponent("\(index).bundle"), executor: executor))
        }
        let staging = try await remote(plan.destination, command: "umask 077; mktemp -d /tmp/graftty-setup.XXXXXXXX").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard staging.hasPrefix("/tmp/graftty-setup."), !staging.contains("\n"), !staging.contains("/../") else {
            throw LinuxHostSetupError.invalidPlan("The Linux host returned an invalid temporary directory.")
        }
        defer {
            let ssh = self.ssh
            let arguments = Self.sshArguments(plan.destination, command: "rm -rf -- \(LinuxHostScripts.quote(staging))")
            // A detached cleanup doesn't inherit cancellation. Only this run's
            // private mktemp directory is removed; repositories remain intact.
            Task.detached { _ = try? await ssh.capture(arguments: arguments, inputFile: nil) }
        }
        await progress(.init(message: "Installing Linux host and user service", completed: 1, total: total))
        let archiveURL = version.map { URL(string: "https://github.com/btucker/graftty/releases/download/v\($0)/graftty-linux-\($0)-\(platform.architecture).tar.gz")! }
        if case .local(let archive) = plan.archive {
            _ = try await remote(plan.destination, command: "umask 077; cat > \(LinuxHostScripts.quote(staging + "/archive.tar.gz"))", inputFile: archive)
        }
        _ = try await remote(plan.destination, command: LinuxHostScripts.install(staging: staging, archiveURL: archiveURL))
        await progress(.init(message: "Exchanging Graftty public identities", completed: 2, total: total))
        let trustFile = local.appendingPathComponent("trust.json")
        try JSONEncoder().encode(plan.client).write(to: trustFile, options: .atomic)
        let response = try await remote(plan.destination, command: "\"$HOME/.local/bin/graftty-host\" trust-client --stdin --json", inputFile: trustFile)
        let identity: LinuxHostIdentity
        do { identity = try JSONDecoder().decode(LinuxHostIdentity.self, from: Data(response.stdout.utf8)) }
        catch { throw LinuxHostSetupError.invalidPlan("The Linux host returned invalid identity JSON. Check that the archive matches the Mac's Graftty version.") }
        try identity.validate()
        var paths: [String] = []
        for (index, project) in plan.projects.enumerated() {
            let path = root + "/" + project.directoryName
            let bundle = staging + "/\(index).bundle"
            await progress(.init(message: "Importing committed history for \(project.directoryName)", completed: 3 + index * 2, total: total))
            _ = try await remote(plan.destination, command: "umask 077; cat > \(LinuxHostScripts.quote(bundle))", inputFile: local.appendingPathComponent("\(index).bundle"))
            _ = try await remote(plan.destination, command: LinuxHostScripts.importRepository(bundle: bundle, destination: path, snapshot: snapshots[index]))
            await progress(.init(message: "Registering \(project.directoryName)", completed: 4 + index * 2, total: total))
            _ = try await remote(plan.destination, command: "\"$HOME/.local/bin/graftty-host\" project add \(LinuxHostScripts.quote(path)) --json")
            paths.append(path)
        }
        try Task.checkCancellation()
        await progress(.init(message: "Connecting to Linux Graftty", completed: total - 1, total: total))
        return LinuxHostSetupResult(identity: identity, openSSH: resolved, destination: plan.destination, projectPaths: paths)
    }

    private func remote(_ destination: LinuxHostDestination, command: String, inputFile: URL? = nil) async throws -> CLIOutput {
        try Task.checkCancellation()
        let output = try await ssh.capture(arguments: Self.sshArguments(destination, command: command), inputFile: inputFile)
        try Task.checkCancellation()
        guard output.exitCode == 0 else { throw LinuxHostSetupError.remoteFailure(output.stderr) }
        return output
    }

    static func sshArguments(_ destination: LinuxHostDestination, command: String) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", destination.value,
         "/bin/sh -c " + LinuxHostScripts.quote(command)]
    }

    static func validVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?$"#, options: .regularExpression) != nil
    }

    public static func validateProjects(_ projects: [LinuxHostProject], destinationRoot: String) throws {
        guard destinationRoot.hasPrefix("/") || destinationRoot.hasPrefix("~/"),
              !destinationRoot.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LinuxHostSetupError.invalidPlan("Enter an absolute Linux project root or a path starting with ~/.")
        }
        var names = Set<String>()
        for project in projects {
            guard project.localPath.hasPrefix("/"), !project.branch.isEmpty,
                  !project.directoryName.isEmpty, project.directoryName != ".", project.directoryName != "..",
                  !project.directoryName.contains("/"), !project.directoryName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  names.insert(project.directoryName).inserted else {
                throw LinuxHostSetupError.invalidPlan("Each selected project needs a local repository, branch, and unique destination folder name.")
            }
        }
    }

    static func validateOrigin(_ origin: String) throws {
        if let url = URLComponents(string: origin), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.user != nil || url.password != nil || url.query != nil || url.fragment != nil {
            throw LinuxHostSetupError.invalidPlan("The origin URL contains credentials or URL parameters. Remove private credentials from the local origin before importing.")
        }
        if let url = URLComponents(string: origin), url.password != nil {
            throw LinuxHostSetupError.invalidPlan("The origin URL contains a password. Remove it before importing.")
        }
    }

    static func prepareBundle(project: LinuxHostProject, output: URL, executor: any CLIExecutor) async throws -> LinuxHostRepositorySnapshot {
        try Task.checkCancellation()
        _ = try await executor.run(command: "git", args: ["check-ref-format", "refs/heads/" + project.branch], at: project.localPath, timeout: .seconds(15))
        let shallow = try await executor.run(command: "git", args: ["rev-parse", "--is-shallow-repository"], at: project.localPath, timeout: .seconds(15))
        guard shallow.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "false" else {
            throw LinuxHostSetupError.invalidPlan("\(project.directoryName) is a shallow repository. Fetch its full history before importing.")
        }
        let commit = try await executor.run(command: "git", args: ["rev-parse", "--verify", "refs/heads/\(project.branch)^{commit}"], at: project.localPath, timeout: .seconds(15)).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let originOutput = try await executor.capture(command: "git", args: ["config", "--get", "remote.origin.url"], at: project.localPath, timeout: .seconds(15))
        guard originOutput.exitCode == 0 || originOutput.exitCode == 1 else {
            throw LinuxHostSetupError.invalidPlan("Could not read \(project.directoryName)'s origin URL.")
        }
        let origin = originOutput.exitCode == 0 ? originOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if let origin { try validateOrigin(origin) }
        _ = try await executor.run(command: "git", args: ["bundle", "create", output.path, "--branches", "--tags"], at: project.localPath, timeout: .seconds(300))
        // A concurrent local commit must not silently change the selected branch
        // between snapshot and bundle creation. Inspect the bundle itself.
        let heads = try await executor.run(command: "git", args: ["bundle", "list-heads", output.path, "refs/heads/" + project.branch], at: project.localPath, timeout: .seconds(15))
        guard heads.stdout.split(separator: "\n").contains(Substring(commit + " refs/heads/" + project.branch)) else {
            throw LinuxHostSetupError.invalidPlan("\(project.directoryName)'s selected branch changed during setup. Retry to capture its new commit.")
        }
        try Task.checkCancellation()
        let source = URL(fileURLWithPath: project.localPath).resolvingSymlinksInPath().standardizedFileURL.path
        let key = SHA256.hash(data: Data((source + "\n" + (origin ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
        return LinuxHostRepositorySnapshot(branch: project.branch, commit: commit, origin: origin, importKey: key)
    }
}
