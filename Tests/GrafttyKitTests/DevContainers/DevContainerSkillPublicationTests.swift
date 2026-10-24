import Foundation
import Testing
@testable import GrafttyKit

struct DevContainerSkillPublicationTests {
    @Test("@spec REMOTE-28.22: When a no-clobber mover returns exit status one, the application shall accept a skipped publication only after verifying its preserved source and identical destination, and reject unsupported movers or incomplete moves.",
          .enabled(if: SkillContainerExecutor.canPublishProjectSkills, "Requires GNU mv or gmv for real no-replace publication"),
          arguments: ["probe", "identical", "conflict", "missing", "partial", "unsupported"])
    func exitOneRequiresVerifiedSkip(mode: String) async throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        try fixture.write("home/.agents/skills/personal/SKILL.md", "personal")
        try fixture.write("project/.agents/skills/local/SKILL.md", "selected")
        try fixture.write("remote/home/keep", "keep")
        try fixture.write("remote/workspace/keep", "keep")
        let workspace = fixture.root.appendingPathComponent("remote/workspace")
        let executor = PublishingSkillExecutor(home: fixture.root.appendingPathComponent("remote/home"), workspace: workspace,
                                               outside: fixture.root, mode: "exit-one-" + mode)
        if mode == "probe" || mode == "identical" {
            _ = try await DevContainerSkillInstaller.install([fixture.capture()], workspace: workspace.path,
                execArguments: ["exec"], operationID: UUID(), executor: executor)
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await DevContainerSkillInstaller.install([fixture.capture()], workspace: workspace.path,
                    execArguments: ["exec"], operationID: UUID(), executor: executor)
            }
        }
        #expect(await executor.injected)
        let destination = workspace.appendingPathComponent(".agents/skills/local")
        if mode == "missing" || mode == "unsupported" {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        } else {
            #expect(try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8) == (mode == "conflict" ? "late conflict" : "selected"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).allSatisfy { !$0.hasPrefix(".graftty-skill.") })
    }

    @Test("@spec REMOTE-28.20: When publishing selected project skills, the application shall reject conflicting late-created or changed destinations, recheck path types and executable flags, and verify the final content before reporting a prepared profile.",
          .enabled(if: SkillContainerExecutor.canPublishProjectSkills, "Requires GNU mv or gmv for real no-replace publication"),
          arguments: ["conflict", "identical", "symlink", "changed-after", "mode-after", "during-move"])
    func rechecksProjectSkillsAcrossPublication(mode: String) async throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        try fixture.write("home/.agents/skills/personal/SKILL.md", "personal")
        try fixture.write("project/.agents/skills/local/SKILL.md", "selected")
        try fixture.write("remote/home/keep", "keep")
        try fixture.write("remote/workspace/keep", "keep")
        try fixture.write("outside/keep", "outside")
        let workspace = fixture.root.appendingPathComponent("remote/workspace")
        let executor = PublishingSkillExecutor(home: fixture.root.appendingPathComponent("remote/home"), workspace: workspace,
                                               outside: fixture.root.appendingPathComponent("outside"), mode: mode)
        if mode == "identical" {
            _ = try await DevContainerSkillInstaller.install([fixture.capture()], workspace: workspace.path,
                execArguments: ["exec"], operationID: UUID(), executor: executor)
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await DevContainerSkillInstaller.install([fixture.capture()], workspace: workspace.path,
                    execArguments: ["exec"], operationID: UUID(), executor: executor)
            }
        }
        #expect(await executor.injected)
        if mode == "symlink" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("outside").path) == ["keep"])
        } else {
            let contents = try String(contentsOf: workspace.appendingPathComponent(".agents/skills/local/SKILL.md"), encoding: .utf8)
            #expect(contents == (mode == "identical" || mode == "mode-after" ? "selected" : "late conflict"))
            if mode == "mode-after" { #expect(FileManager.default.isExecutableFile(atPath: workspace.appendingPathComponent(".agents/skills/local/SKILL.md").path)) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent(".agents/skills").path) == ["local"])
        }
    }

    @Test("@spec REMOTE-28.21: If safe project-directory publication is unavailable, then the application shall reject missing project skills with an actionable prerequisite while allowing user-only skills and identical existing project skills.", arguments: ["user-only", "existing", "missing"])
    func publicationCapabilityIsNeededOnlyForMissingProjectSkills(mode: String) async throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        try fixture.write("home/.agents/skills/personal/SKILL.md", "personal")
        try fixture.write("remote/home/keep", "keep")
        try fixture.write("remote/workspace/keep", "keep")
        if mode != "user-only" { try fixture.write("project/.agents/skills/local/SKILL.md", "selected") }
        if mode == "existing" { try fixture.write("remote/workspace/.agents/skills/local/SKILL.md", "selected") }
        let workspace = fixture.root.appendingPathComponent("remote/workspace")
        let executor = PublishingSkillExecutor(home: fixture.root.appendingPathComponent("remote/home"), workspace: workspace,
                                               outside: fixture.root, mode: "no-mover")
        do {
            _ = try await DevContainerSkillInstaller.install([fixture.capture()], workspace: workspace.path,
                execArguments: ["exec"], operationID: UUID(), executor: executor)
            #expect(mode != "missing", "Missing project skills were published without a safe mover")
        } catch {
            #expect(mode == "missing")
            #expect(String(describing: error).contains("GNU mv"))
            #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".agents/skills/local").path))
        }
    }
}

private actor PublishingSkillExecutor: CLIExecutor {
    let inner: SkillContainerExecutor
    let workspace: URL
    let outside: URL
    let mode: String
    var injected = false

    init(home: URL, workspace: URL, outside: URL, mode: String) {
        inner = SkillContainerExecutor(home: home, workspace: workspace)
        self.workspace = workspace; self.outside = outside; self.mode = mode
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        var args = args
        if mode == "no-mover", let script = args.last, args.contains("/bin/sh") {
            args[args.count - 1] = "mv() { return 64; }; gmv() { return 64; };\n" + script
        }
        if mode == "during-move", let script = args.last, args.contains("/bin/sh") {
            // Execute the real mover after a competing creator wins the exact
            // publication boundary. Probes still exercise the real mv/gmv too.
            let race = "case \"$3\" in */content) mkdir -p \"$4\"; printf 'late conflict' > \"$4/SKILL.md\";; esac; "
            args[args.count - 1] = "mv() { " + race + "command mv \"$@\"; };\ngmv() { " + race + "command gmv \"$@\"; };\n" + script
        }
        if mode.hasPrefix("exit-one-"), let script = args.last, args.contains("/bin/sh") {
            let action: String
            switch mode {
            case "exit-one-identical": action = "cp -R \"$4\" \"$5\""
            case "exit-one-conflict": action = "mkdir -p \"$5\"; printf 'late conflict' > \"$5/SKILL.md\""
            case "exit-one-missing": action = "return 1"
            case "exit-one-partial": action = "cp -R \"$4\" \"$5\"; rm \"$4/SKILL.md\"; return 1"
            default: action = ":"
            }
            // Keep real mover semantics, but reproduce Coreutils versions
            // which return one when no-clobber preserves an existing target.
            args[args.count - 1] = """
            graftty_test_move() {
              \(mode == "exit-one-unsupported" ? "return 1" : ":")
              case "$4" in */content) \(action);; esac
              graftty_test_move_status=0
              command "$@" || graftty_test_move_status=$?
              if test -d "$4" && test -d "$5"; then return 1; fi
              return "$graftty_test_move_status"
            }
            mv() { graftty_test_move mv "$@"; }
            gmv() { graftty_test_move gmv "$@"; }
            """ + "\n" + script
        }
        let publishing = !injected && args.last?.contains("ln -s ") == true && mode != "no-mover"
        if publishing {
            injected = true
            if mode == "symlink" {
                try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent(".agents"), withDestinationURL: outside)
            } else if !["changed-after", "mode-after", "during-move"].contains(mode) && !mode.hasPrefix("exit-one-") { try writeLateContent() }
        }
        let result = try await inner.run(command: command, args: args, at: directory)
        if publishing && mode == "changed-after" { try writeLateContent() }
        if publishing && mode == "mode-after" {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.appendingPathComponent(".agents/skills/local/SKILL.md").path)
        }
        return result
    }

    private func writeLateContent() throws {
        let target = workspace.appendingPathComponent(".agents/skills/local/SKILL.md")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((mode == "identical" ? "selected" : "late conflict").utf8).write(to: target)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}
