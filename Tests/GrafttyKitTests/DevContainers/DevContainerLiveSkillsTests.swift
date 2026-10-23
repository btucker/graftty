import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Opt in with an existing Docker image containing Git, sh, base64, and diff,
/// and the upstream devcontainer executable on PATH. No agent login is used.
struct DevContainerLiveSkillsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TEST_DEVCONTAINER_IMAGE"] != nil), arguments: [false, true])
    func installsSkillsInLinuxContainerAndRetainsThemAcrossRestart(durable: Bool) async throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        try fixture.write("home/.agents/skills/personal/SKILL.md", "personal codex skill")
        try fixture.write("home/.claude/skills/personal/SKILL.md", "personal claude skill")
        try fixture.write("project/.agents/skills/local/SKILL.md", "project codex skill")
        try fixture.write("project/.agents/skills/local/run.sh", "#!/bin/sh\nprintf 'skill-executed'\n", executable: true)
        try fixture.write("project/.claude/skills/local/SKILL.md", "project claude skill")
        let snapshots = try [fixture.capture(.codex), fixture.capture(.claude)]
        let workspace = CanonicalPath.canonicalize(fixture.root.appendingPathComponent("workspace").path)
        let image = try #require(ProcessInfo.processInfo.environment["GRAFTTY_TEST_DEVCONTAINER_IMAGE"])
        var config: [String: Any] = [
            "image": image,
            "userEnvProbe": "none",
        ]
        if durable && geteuid() != 0 {
            // Match the real Linux host contract even on Docker Desktop, which
            // does not normalize the remote UID the same way as Linux.
            try fixture.write("workspace/.devcontainer/Dockerfile", "FROM \(image)\nRUN useradd --non-unique --uid \(geteuid()) --create-home graftty-profile-test\n")
            config.removeValue(forKey: "image")
            config["build"] = ["dockerfile": "Dockerfile"]
            config["remoteUser"] = "graftty-profile-test"
        }
        let configuration = try JSONSerialization.data(withJSONObject: config)
        try fixture.write("workspace/.devcontainer/devcontainer.json", String(decoding: configuration, as: UTF8.self))
        let runner = DevContainerCommandRunner()
        _ = try await runner.run(command: "git", args: ["init", "--quiet"], at: workspace, timeout: .seconds(10))
        let preparer = DevContainerPreparer(executor: runner, profileDirectory: durable ? fixture.root.appendingPathComponent("profiles") : nil)
        let operation = UUID()
        func cleanup() async throws {
            if let id = try await preparer.findPlacementContainer(operationID: operation, workspace: workspace) {
                _ = try await preparer.stopForDeletion(containerID: id)
                try await preparer.removeStoppedContainer(containerID: id)
            }
        }
        do {
            let prepared = try await preparer.prepare(workspace: workspace, operationID: operation, skills: snapshots)
            let profile = try #require(prepared.agentSkillHome)
            #expect(!prepared.agentReady)
            let command = DevContainerPreparer.shellCommand(for: prepared, command: """
            set -eu
            test "$(uname -s)" = Linux
            test "$CODEX_HOME" = "$HOME/.codex"
            test "$CLAUDE_CONFIG_DIR" = "$HOME/.claude"
            test "$(cat "$HOME/.agents/skills/personal/SKILL.md")" = 'personal codex skill'
            test "$(cat "$HOME/.claude/skills/personal/SKILL.md")" = 'personal claude skill'
            test "$(cat .agents/skills/local/SKILL.md)" = 'project codex skill'
            test "$(cat .claude/skills/local/SKILL.md)" = 'project claude skill'
            test "$(.agents/skills/local/run.sh)" = skill-executed
            test ! -L .agents/skills/local
            mkdir -p "$CODEX_HOME/skills/.system"
            printf 'runtime-owned' > "$CODEX_HOME/skills/.system/keep"
            mkdir -p "$CODEX_HOME/sessions"
            printf 'session-file-retention-probe' > "$CODEX_HOME/sessions/fixture.jsonl"
            git status --porcelain
            exit
            """)
            let output = try await runner.run(command: "/bin/sh", args: ["-c", command], at: workspace, timeout: .seconds(60))
            #expect(output.stdout.contains(".agents/") && output.stdout.contains(".claude/"))
            #expect(try await preparer.stopForDeletion(containerID: prepared.containerID))
            try await preparer.restartAfterRejectedDeletion(containerID: prepared.containerID)
            let check = DevContainerPreparer.shellCommand(for: prepared, command:
                "test \"$(cat \"$CODEX_HOME/skills/.system/keep\")\" = runtime-owned && test \"$HOME\" = " +
                WorktreeAgentLaunchCommand.shellLiteral(profile) + "\nexit $?")
            _ = try await runner.run(command: "/bin/sh", args: ["-c", check], at: workspace, timeout: .seconds(60))
            try await cleanup()
            #expect(try await preparer.findPlacementContainer(operationID: operation, workspace: workspace) == nil)
            if durable {
                #expect(try String(contentsOfFile: profile + "/.codex/sessions/fixture.jsonl", encoding: .utf8) == "session-file-retention-probe")
                let replacement = try await preparer.prepare(workspace: workspace, operationID: operation, skills: snapshots)
                #expect(replacement.containerID != prepared.containerID)
                let retained = DevContainerPreparer.shellCommand(for: replacement, command:
                    "test \"$(cat " + WorktreeAgentLaunchCommand.shellLiteral(profile + "/.codex/sessions/fixture.jsonl") +
                    ")\" = session-file-retention-probe\nexit $?")
                _ = try await runner.run(command: "/bin/sh", args: ["-c", retained], at: workspace, timeout: .seconds(60))
                try await cleanup()
            }
        } catch {
            try await cleanup()
            throw error
        }
    }
}
