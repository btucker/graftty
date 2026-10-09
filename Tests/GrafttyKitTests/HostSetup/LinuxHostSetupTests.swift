import Foundation
import Testing
@testable import GrafttyKit

struct LinuxHostSetupTests {
    private static var gnuMove: String? {
        #if os(Linux)
        return "/bin/mv"
        #else
        return ["/opt/homebrew/bin/gmv", "/usr/local/bin/gmv"].first { FileManager.default.isExecutableFile(atPath: $0) }
        #endif
    }
    private static var movePrefix: String {
        "mv() { " + LinuxHostScripts.quote(gnuMove!) + " \"$@\"; };\n"
    }

    @Test("@spec REMOTE-21.1: When Linux setup receives an OpenSSH alias or user destination, the application shall preserve that destination and quote remote arguments without accepting SSH option injection.")
    func destinationAndQuoting() throws {
        #expect(try LinuxHostDestination("dev-server").value == "dev-server")
        #expect(try LinuxHostDestination("alice@192.0.2.1").value == "alice@192.0.2.1")
        for value in ["", "-oProxyCommand=evil", "host name", "host\nname", "ssh://host"] {
            #expect(throws: LinuxHostSetupError.self) { try LinuxHostDestination(value) }
        }
        #expect(LinuxHostScripts.quote("a'b $HOME; x") == "'a'\\''b $HOME; x'")
    }

    @Test("@spec REMOTE-21.2: If the destination is not Ubuntu 24.04 on x86_64 or ARM64 or lacks required dependencies, then the application shall stop setup with an actionable error.")
    func platformAndDependencies() throws {
        #expect(try LinuxHostPlatform.parse("ubuntu\n24.04\nx86_64\n/home/alice\n").architecture == "x86_64")
        #expect(try LinuxHostPlatform.parse("ubuntu\n24.04\naarch64\n/home/alice\n").architecture == "aarch64")
        #expect(throws: LinuxHostSetupError.self) { try LinuxHostPlatform.parse("debian\n24.04\nx86_64\n/home/alice\n") }
        #expect(throws: LinuxHostSetupError.self) { try LinuxHostPlatform.parse("ubuntu\n24.04\ns390x\n/home/alice\n") }
        #expect(throws: LinuxHostSetupError.self) { try LinuxHostPlatform.parse("ubuntu\n22.04\nx86_64\n/home/alice\n") }
        #expect(throws: LinuxHostSetupError.self) { try LinuxHostPlatform.parse("ubuntu\n26.04\naarch64\n/home/alice\n") }
        #expect(LinuxHostSetupError.remoteFailure("GRAFTTY_MISSING:git").localizedDescription.contains("git"))
    }

    @Test("@spec REMOTE-21.3: When Linux setup imports a project, the application shall preserve all local branch and tag history including unpushed commits, check out the selected branch, and exclude working changes, untracked files, and ignored files.")
    func bundleContainsOnlyHistory() async throws {
        let fixture = try await RepositoryFixture.make()
        defer { fixture.remove() }
        _ = try await CLIRunner().run(command: "git", args: ["checkout", "main"], at: fixture.repository.path)
        _ = try await CLIRunner().run(command: "git", args: ["tag", "release-test", "feature"], at: fixture.repository.path)
        try "dirty private edit".write(to: fixture.repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: fixture.repository.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
        try "ignored secret".write(to: fixture.repository.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        let bundle = fixture.root.appendingPathComponent("transfer.bundle")
        let project = LinuxHostProject(localPath: fixture.repository.path, branch: "feature", directoryName: "app")
        let snapshot = try await LinuxHostSetup.prepareBundle(project: project, output: bundle, executor: CLIRunner())
        #expect(snapshot.branch == "feature")
        let clone = fixture.root.appendingPathComponent("clone")
        _ = try await CLIRunner().run(command: "git", args: ["clone", "--branch", "feature", bundle.path, clone.path], at: fixture.root.path)
        #expect(try String(contentsOf: clone.appendingPathComponent("tracked.txt"), encoding: .utf8) == "committed feature")
        #expect(!FileManager.default.fileExists(atPath: clone.appendingPathComponent("private.txt").path))
        #expect(!FileManager.default.fileExists(atPath: clone.appendingPathComponent("ignored.txt").path))
        let head = try await CLIRunner().run(command: "git", args: ["rev-parse", "HEAD"], at: clone.path)
        #expect(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot.commit)
        #expect(try await CLIRunner().run(command: "git", args: ["tag", "--list"], at: clone.path).stdout.contains("release-test"))
    }

    @Test("@spec REMOTE-21.4: When Linux setup retries a repository import, the application shall reuse only its own clean checkout at the imported commit and refuse unrelated, dirty, or advanced destination repositories.", .enabled(if: gnuMove != nil, "Requires GNU mv for the Ubuntu publication command"))
    func safeRetry() async throws {
        let fixture = try await RepositoryFixture.make()
        defer { fixture.remove() }
        let bundle = fixture.root.appendingPathComponent("transfer.bundle")
        let project = LinuxHostProject(localPath: fixture.repository.path, branch: "feature", directoryName: "app")
        let snapshot = try await LinuxHostSetup.prepareBundle(project: project, output: bundle, executor: CLIRunner())
        let destination = fixture.root.appendingPathComponent("remote app's $d")
        let script = Self.movePrefix + LinuxHostScripts.importRepository(bundle: bundle.path, destination: destination.path, snapshot: snapshot)
        _ = try await CLIRunner().run(command: "/bin/sh", args: ["-c", script], at: fixture.root.path)
        _ = try await CLIRunner().run(command: "/bin/sh", args: ["-c", script], at: fixture.root.path)
        let origin = try await CLIRunner().run(command: "git", args: ["remote", "get-url", "origin"], at: destination.path)
        #expect(origin.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "git@example.test:org/app.git")
        try "dirty".write(to: destination.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let refused = try await CLIRunner().capture(command: "/bin/sh", args: ["-c", script], at: fixture.root.path)
        #expect(refused.exitCode != 0)
        #expect(refused.stderr.contains("GRAFTTY_REPOSITORY_CONFLICT"))
        #expect(try String(contentsOf: destination.appendingPathComponent("tracked.txt"), encoding: .utf8) == "dirty")
        let unrelated = fixture.root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let other = Self.movePrefix + LinuxHostScripts.importRepository(bundle: bundle.path, destination: unrelated.path, snapshot: snapshot)
        #expect(try await CLIRunner().capture(command: "/bin/sh", args: ["-c", other], at: fixture.root.path).exitCode != 0)
        _ = try await CLIRunner().run(command: "git", args: ["checkout", "--", "tracked.txt"], at: destination.path)
        _ = try await CLIRunner().run(command: "git", args: ["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "remote work"], at: destination.path)
        #expect(try await CLIRunner().capture(command: "/bin/sh", args: ["-c", script], at: fixture.root.path).exitCode != 0)
        let symlink = fixture.root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)
        let symlinkScript = Self.movePrefix + LinuxHostScripts.importRepository(bundle: bundle.path, destination: symlink.path, snapshot: snapshot)
        #expect(try await CLIRunner().capture(command: "/bin/sh", args: ["-c", symlinkScript], at: fixture.root.path).exitCode != 0)
        let raced = fixture.root.appendingPathComponent("raced")
        let racePrefix = "mv() { mkdir \"$4\"; printf external > \"$4/sentinel\"; " + LinuxHostScripts.quote(Self.gnuMove!) + " \"$@\"; };\n"
        let raceScript = racePrefix + LinuxHostScripts.importRepository(bundle: bundle.path, destination: raced.path, snapshot: snapshot)
        #expect(try await CLIRunner().capture(command: "/bin/sh", args: ["-c", raceScript], at: fixture.root.path).exitCode != 0)
        #expect(try String(contentsOf: raced.appendingPathComponent("sentinel"), encoding: .utf8) == "external")
        #expect(!FileManager.default.fileExists(atPath: raced.appendingPathComponent(".git").path))
    }

    @Test(.enabled(if: gnuMove != nil, "Requires GNU mv"), arguments: [true, false])
    func preservesEveryLocalBranch(hasOrigin: Bool) async throws {
        let fixture = try await RepositoryFixture.make()
        defer { fixture.remove() }
        let runner = CLIRunner()
        _ = try await runner.run(command: "git", args: ["checkout", "-b", "other", "main"], at: fixture.repository.path)
        _ = try await runner.run(command: "git", args: ["commit", "--allow-empty", "-m", "other unpushed commit"], at: fixture.repository.path)
        let otherCommit = try await runner.run(command: "git", args: ["rev-parse", "refs/heads/other"], at: fixture.repository.path).stdout
        if !hasOrigin { _ = try await runner.run(command: "git", args: ["remote", "remove", "origin"], at: fixture.repository.path) }
        let bundle = fixture.root.appendingPathComponent("all-branches.bundle")
        let project = LinuxHostProject(localPath: fixture.repository.path, branch: "feature", directoryName: "app")
        let snapshot = try await LinuxHostSetup.prepareBundle(project: project, output: bundle, executor: runner)
        let destination = fixture.root.appendingPathComponent("imported")
        let script = Self.movePrefix + LinuxHostScripts.importRepository(bundle: bundle.path, destination: destination.path, snapshot: snapshot)
        _ = try await runner.run(command: "/bin/sh", args: ["-c", script], at: fixture.root.path)
        #expect(try await runner.run(command: "git", args: ["rev-parse", "refs/heads/other"], at: destination.path).stdout == otherCommit)
        #expect(try await runner.run(command: "git", args: ["rev-parse", "refs/heads/main"], at: destination.path).exitCode == 0)
    }

    @Test(.enabled(if: gnuMove != nil, "Requires GNU mv"))
    func corruptStatusMustRefuseRetry() async throws {
        let fixture = try await RepositoryFixture.make()
        defer { fixture.remove() }
        let runner = CLIRunner()
        let bundle = fixture.root.appendingPathComponent("transfer.bundle")
        let snapshot = try await LinuxHostSetup.prepareBundle(project: .init(localPath: fixture.repository.path, branch: "feature", directoryName: "app"), output: bundle, executor: runner)
        let destination = fixture.root.appendingPathComponent("corrupt-index")
        let script = Self.movePrefix + LinuxHostScripts.importRepository(bundle: bundle.path, destination: destination.path, snapshot: snapshot)
        _ = try await runner.run(command: "/bin/sh", args: ["-c", script], at: fixture.root.path)
        try Data("corrupt index".utf8).write(to: destination.appendingPathComponent(".git/index"))
        try "dirty".write(to: destination.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let retry = try await runner.capture(command: "/bin/sh", args: ["-c", script], at: fixture.root.path)
        #expect(retry.exitCode != 0)
        #expect(retry.stderr.contains("GRAFTTY_REPOSITORY_CONFLICT"))
        #expect(try String(contentsOf: destination.appendingPathComponent("tracked.txt"), encoding: .utf8) == "dirty")
    }

    @Test("@spec REMOTE-21.5: If OpenSSH rejects the host key or authentication, then the application shall explain how to resolve it with system SSH without disabling host-key verification.")
    func sshErrors() {
        #expect(LinuxHostSetupError.remoteFailure("Host key verification failed.").localizedDescription.contains("Terminal"))
        #expect(LinuxHostSetupError.remoteFailure("Permission denied (publickey).").localizedDescription.contains("ssh-agent"))
    }

    @Test("@spec REMOTE-21.6: When Linux setup validates a plan, the application shall reject overlapping destination names, relative destination roots, and origins containing private URL credentials.")
    func planValidation() throws {
        let project = LinuxHostProject(localPath: "/tmp/repo", branch: "main", directoryName: "app")
        #expect(throws: LinuxHostSetupError.self) { try LinuxHostSetup.validateProjects([project, project], destinationRoot: "/tmp/projects") }
        #expect(throws: LinuxHostSetupError.self) { try LinuxHostSetup.validateProjects([project], destinationRoot: "relative") }
        #expect(throws: LinuxHostSetupError.self) { try LinuxHostSetup.validateOrigin("https://token@example.com/repo.git") }
        #expect(throws: LinuxHostSetupError.self) { try LinuxHostSetup.validateOrigin("https://alice:password@example.com/repo.git") }
        try LinuxHostSetup.validateOrigin("git@example.com:org/repo.git")
    }
}

private struct RepositoryFixture {
    let root: URL
    let repository: URL
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-setup-test-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let runner = CLIRunner()
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.test"], ["remote", "add", "origin", "git@example.test:org/app.git"]] {
            _ = try await runner.run(command: "git", args: args, at: repository.path)
        }
        try "committed main".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "ignored.txt\n".write(to: repository.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await runner.run(command: "git", args: ["add", "."], at: repository.path)
        _ = try await runner.run(command: "git", args: ["commit", "-m", "main"], at: repository.path)
        _ = try await runner.run(command: "git", args: ["checkout", "-b", "feature"], at: repository.path)
        try "committed feature".write(to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(command: "git", args: ["commit", "-am", "unpushed"], at: repository.path)
        return Self(root: root, repository: repository)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
