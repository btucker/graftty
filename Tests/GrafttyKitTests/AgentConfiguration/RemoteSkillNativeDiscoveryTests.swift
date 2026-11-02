import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Opt-in compatibility checks against installed native agents. No model turn,
/// parent credentials, plugins, or hooks are passed to either child process.
struct RemoteSkillNativeDiscoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TEST_CODEX_BINARY"] != nil))
    func codexDiscoversStagedUserAndProjectSkills() async throws {
        try await verify(.codex, binary: #require(ProcessInfo.processInfo.environment["GRAFTTY_TEST_CODEX_BINARY"]))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TEST_CLAUDE_BINARY"] != nil))
    func claudeDiscoversStagedUserAndProjectSkills() async throws {
        try await verify(.claude, binary: #require(ProcessInfo.processInfo.environment["GRAFTTY_TEST_CLAUDE_BINARY"]))
    }

    private func verify(_ runtime: TeamHookRuntime, binary: String) async throws {
        let fixture = try SkillFixture()
        defer { fixture.remove() }
        let userRoot = runtime == .codex ? ".codex" : ".claude"
        let projectRoot = runtime == .codex ? ".agents" : ".claude"
        func text(_ name: String) -> String {
            "---\nname: \(name)\ndescription: Fixture for Graftty skill discovery validation only.\n---\nUse only in this fixture.\n"
        }
        try fixture.write("home/\(userRoot)/skills/graftty-probe-personal/SKILL.md", text("graftty-probe-personal"))
        try fixture.write("project/\(projectRoot)/skills/graftty-probe-project/SKILL.md", text("graftty-probe-project"))
        if runtime == .codex { try fixture.write("home/.agents/skills/graftty-probe-modern/SKILL.md", text("graftty-probe-modern")) }
        let snapshot = try fixture.capture(runtime)
        _ = try RemoteSkillStore(directory: fixture.root.appendingPathComponent("store"))
            .stage(fixture.capture(runtime), parentID: "fixture-parent", projectID: "fixture-project")
        let workspace = fixture.root.appendingPathComponent("native-workspace")
        let containerHome = fixture.root.appendingPathComponent("container-home")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: containerHome, withIntermediateDirectories: true)
        let profilePath = try await DevContainerSkillInstaller.install([snapshot], workspace: workspace.path, execArguments: ["exec"],
            operationID: UUID(), executor: SkillContainerExecutor(home: containerHome, workspace: workspace))
        let profile = URL(fileURLWithPath: profilePath)
        var environment = ["PATH": "/usr/bin:/bin:/usr/local/bin", "TMPDIR": FileManager.default.temporaryDirectory.path, "HOME": profile.path]
        environment["CODEX_HOME"] = profile.appendingPathComponent(".codex").path
        environment["CLAUDE_CONFIG_DIR"] = profile.appendingPathComponent(".claude").path
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        let args = runtime == .codex ? ["app-server", "--listen", "stdio://"] :
            ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--settings", "{\"disableAllHooks\":true}"]
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cd \"$1\" && shift && exec \"$@\"", "graftty-skill-probe", workspace.path, binary] + args,
            environment: environment)
        let stream = NativeAgentProbeStream(child: child)
        let names: Set<String>
        if runtime == .codex {
            try stream.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "graftty_skill_probe", "version": "1"], "capabilities": ["experimentalApi": true]]])
            let initialized = try stream.receive { ($0["id"] as? Int) == 1 }
            #expect(initialized["error"] == nil)
            try stream.send(["method": "initialized", "params": [:]])
            try stream.send(["id": 2, "method": "skills/list", "params": ["cwds": [workspace.path], "forceReload": true]])
            let response = try stream.receive { ($0["id"] as? Int) == 2 }
            let result = try #require(response["result"] as? [String: Any])
            let entries = try #require(result["data"] as? [[String: Any]])
            let skills = entries.flatMap { $0["skills"] as? [[String: Any]] ?? [] }
            names = Set(skills.compactMap { $0["name"] as? String })
            #expect(skills.contains { $0["name"] as? String == "graftty-probe-personal" && $0["scope"] as? String == "user" })
            #expect(skills.contains { $0["name"] as? String == "graftty-probe-project" && $0["scope"] as? String == "repo" })
        } else {
            try stream.send(["type": "control_request", "request_id": "fixture-init", "request": ["subtype": "initialize"]])
            let response = try stream.receive { $0["type"] as? String == "control_response" }
            let envelope = try #require(response["response"] as? [String: Any])
            #expect(envelope["subtype"] as? String == "success")
            let result = try #require(envelope["response"] as? [String: Any])
            let commands = try #require(result["commands"] as? [[String: Any]])
            names = Set(commands.compactMap { $0["name"] as? String })
        }
        #expect(names.contains("graftty-probe-personal"))
        #expect(names.contains("graftty-probe-project"))
        if runtime == .codex { #expect(names.contains("graftty-probe-modern")) }
        let installedSource = profile.deletingLastPathComponent().appendingPathComponent("source/" + runtime.rawValue)
        for file in snapshot.files {
            #expect(try Data(contentsOf: installedSource.appendingPathComponent(RemoteSkillSnapshot.key(file))) == file.contents)
        }
        #expect(!FileManager.default.fileExists(atPath: installedSource.appendingPathComponent("user/.codex/skills/.system").path))
        // Child deinit kills and reaps its process group on every exit path.
        // Discovery must not mutate the staged configuration.
        _ = try RemoteSkillStore(directory: fixture.root.appendingPathComponent("store"))
            .stage(fixture.capture(runtime), parentID: "fixture-parent", projectID: "fixture-project")
    }
}
