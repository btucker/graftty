import Foundation
@testable import GrafttyKit
import Testing

struct LinuxHostAgentInstallTests {
    @Test("@spec REMOTE-21.16: When an agent CLI already exists in the login shell PATH, Linux setup shall verify it without installing or replacing it.", arguments: [TeamHookRuntime.claude, .codex])
    func existingCLI(provider: TeamHookRuntime) async throws {
        let f = try AgentInstallFixture(); defer { f.remove() }
        try f.executable(f.profile.appendingPathComponent(provider.rawValue), "echo existing >> \"$HOME/versions\"")
        let result = try await f.run(provider)
        #expect(result.exitCode == 0)
        #expect(f.contents("versions").contains("existing"))
        #expect(f.contents("downloads").isEmpty)
        #expect(result.stdout.isEmpty)
    }

    @Test("@spec REMOTE-21.17: When a selected agent CLI is absent, Linux setup shall download its official installer with bounded commands and verify the installed executable before continuing.", arguments: [TeamHookRuntime.claude, .codex])
    func installsMissingCLI(provider: TeamHookRuntime) async throws {
        let f = try AgentInstallFixture(); defer { f.remove() }
        let result = try await f.run(provider)
        #expect(result.exitCode == 0)
        #expect(f.contents("downloads").contains(provider == .claude ? "https://claude.ai/install.sh" : "https://chatgpt.com/codex/install.sh"))
        #expect(f.contents("versions").contains("installed-" + provider.rawValue))
        #expect(f.contents("installer-paths").trimmingCharacters(in: .newlines) == f.profile.path + ":" + f.tools.path + ":/usr/bin:/bin")
        #expect(f.contents("downloads").contains("--max-time 60"))
        #expect(f.contents("downloads").contains("--proto =https --proto-redir =https"))
        #expect(f.contents("timeouts").contains("--kill-after=1 300"))
        #expect(f.contents("timeouts").contains("--kill-after=1 15"))
        #expect(f.contents("locks").contains("-w 30"))
        #expect(result.stdout.isEmpty)
    }

    @Test("@spec REMOTE-21.18: If agent discovery, download, installation, or verification fails, Linux setup shall report the provider and retry guidance without replacing an existing executable.", arguments: ["probe", "emptyprobe", "download", "install", "missing", "broken"])
    func failuresAreActionable(mode: String) async throws {
        let f = try AgentInstallFixture(); defer { f.remove() }
        if mode == "broken" { try f.executable(f.profile.appendingPathComponent("codex"), "echo fixture-version-error >&2; exit 9") }
        let result = try await f.run(.codex, mode: mode)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("codex"))
        #expect(result.stderr.lowercased().contains("retry"))
        if mode == "install" { #expect(result.stderr.contains("fixture-installer-error")) }
        if mode == "download" { #expect(result.stderr.contains("fixture-download-error")) }
        if mode == "broken" { #expect(result.stderr.contains("fixture-version-error")) }
        if mode == "probe" || mode == "emptyprobe" || mode == "broken" { #expect(f.contents("downloads").isEmpty) }
    }

    @Test("@spec REMOTE-21.19: When agent setup is retried or login profiles print output, Linux setup shall preserve PATH precedence, isolate profile output, and install only executables still missing.", arguments: [false, true])
    func noisyProfileRetryAndBothProviders(existingClaude: Bool) async throws {
        let f = try AgentInstallFixture(); defer { f.remove() }
        if existingClaude {
            try f.executable(f.profile.appendingPathComponent("claude"), "echo profile-claude >> \"$HOME/versions\"")
            try f.executable(f.local.appendingPathComponent("claude"), "echo wrong-claude >> \"$HOME/versions\"")
        }
        #expect(try await f.run(.claude).exitCode == 0)
        #expect(try await f.run(.codex, mode: "install").exitCode != 0)
        #expect(try await f.run(.codex).exitCode == 0)
        #expect(try await f.run(.codex).exitCode == 0)
        #expect(f.contents("downloads").split(separator: "\n").count == (existingClaude ? 2 : 3))
        #expect(f.contents("versions").contains(existingClaude ? "profile-claude" : "installed-claude"))
        #expect(!f.contents("versions").contains("wrong-claude"))
    }
}

private struct AgentInstallFixture {
    let root: URL
    var profile: URL { root.appendingPathComponent("profile bin") }
    var tools: URL { root.appendingPathComponent("tools") }
    var local: URL { root.appendingPathComponent(".local/bin") }
    var staging: URL { root.appendingPathComponent("staging ' quoted") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-install-\(UUID())")
        for directory in [profile, tools, local, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try executable(tools.appendingPathComponent("timeout"), "printf '%s\\n' \"$*\" >> \"$HOME/timeouts\"; shift 2; exec \"$@\"")
        try executable(tools.appendingPathComponent("flock"), "printf '%s\\n' \"$*\" >> \"$HOME/locks\"")
        try executable(tools.appendingPathComponent("login-shell"), """
        echo 'noisy shell startup'; echo 'noisy shell stderr' >&2
        test "$MODE" != probe || exit 7
        test "$MODE" != emptyprobe || exit 0
        test "$1" = -ilc || exit 98
        PATH="$HOME/profile bin:$HOME/tools:/usr/bin:/bin"; export PATH
        exec /bin/sh -c "$2"
        """)
        try executable(tools.appendingPathComponent("curl"), """
        printf '%s\\n' "$*" >> "$HOME/downloads"
        test "$MODE" != download || { echo fixture-download-error >&2; exit 8; }
        output=
        while test "$#" -gt 0; do
          case "$1" in --output) output=$2; shift;; esac
          shift
        done
        cp "$HOME/fixture-installer" "$output"
        """)
        try executable(root.appendingPathComponent("fixture-installer"), """
        printf '%s\\n' "$PATH" >> "$HOME/installer-paths"
        test "$MODE" != install || { echo fixture-installer-error >&2; exit 9; }
        test "$MODE" != missing || exit 0
        case "$PROVIDER" in
          claude) test "$*" = stable || exit 91;;
          codex) test "${CODEX_NON_INTERACTIVE:-}" = true || exit 92
                 test "${CODEX_INSTALL_DIR:-}" = "$HOME/.local/bin" || exit 93;;
        esac
        if read -r unexpected; then exit 94; fi
        printf '#!/bin/sh\\necho installed-%s >> "$HOME/versions"\\n' "$PROVIDER" > "$HOME/.local/bin/$PROVIDER"
        chmod +x "$HOME/.local/bin/$PROVIDER"
        """)
    }
    func executable(_ url: URL, _ body: String) throws {
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func run(_ provider: TeamHookRuntime, mode: String = "ok") async throws -> CLIOutput {
        let environment = """
        export HOME=\(LinuxHostScripts.quote(root.path))
        export XDG_DATA_HOME="$HOME/custom data"
        export SHELL="$HOME/tools/login-shell"
        export PATH="$HOME/tools:/usr/bin:/bin"
        export MODE=\(LinuxHostScripts.quote(mode)) PROVIDER=\(LinuxHostScripts.quote(provider.rawValue))
        """
        return try await CLIRunner().capture(command: "/bin/sh", args: ["-c", environment + "\n" + LinuxHostScripts.ensureAgentCLI(provider: provider, staging: staging.path)], at: root.path)
    }
    func contents(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
