import Foundation
import Testing
@testable import GrafttyKit

@Suite("Agent Hook Installer")
struct AgentHookInstallerTests {
    @Test func installWritesWrappersIdempotently() throws {
        let root = try Self.temporaryDirectory()
        let installer = AgentHookInstaller(rootDirectory: root, grafttyCLIPath: "/usr/local/bin/graftty")

        let first = try installer.install()
        let second = try installer.install()

        // Two wrappers (claude, codex) + four zsh-init shim files
        // (.zshenv, .zprofile, .zshrc, .zlogin) + two bash-init files
        // (bash-launcher, .bashrc) = 8.
        #expect(first.writtenFiles.count == 8)
        #expect(second.writtenFiles.isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/claude").path))
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/codex").path))
        for shim in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let path = root.appendingPathComponent("zsh-init").appendingPathComponent(shim).path
            #expect(FileManager.default.fileExists(atPath: path))
        }
        let bashLauncher = root.appendingPathComponent("bash-init/bash-launcher").path
        #expect(FileManager.default.isExecutableFile(atPath: bashLauncher))
        let bashRC = root.appendingPathComponent("bash-init/.bashrc").path
        #expect(FileManager.default.fileExists(atPath: bashRC))
    }

    @Test func bashrcShimSourcesUserBashrcAndPrependsAgentBin() {
        let shim = AgentHookInstaller.bashrcShim()
        #expect(shim.contains(#"source "$HOME/.bashrc""#))
        #expect(shim.contains("GRAFTTY_AGENT_HOOKS_BIN"))
        #expect(shim.contains(#"export PATH="$GRAFTTY_AGENT_HOOKS_BIN:$PATH""#))
        // Strip-then-prepend so nested bash invocations don't accumulate
        // duplicates.
        #expect(shim.contains(#"_graftty_path="${_graftty_path//:$GRAFTTY_AGENT_HOOKS_BIN:/:}""#))
    }

    @Test("""
    @spec ZMX-6.7: When the user's shell is bash and agent hooks are enabled, the launcher script continues to invoke `bash --rcfile <shim>` (non-login, so `--rcfile` is honored), and the shim shall source the system + user profile chain (`/etc/profile`; first existing of `~/.bash_profile`, `~/.bash_login`, `~/.profile`) once per environment via an idempotency guard env variable (`__GRAFTTY_BASH_PROFILE_SOURCED`), before sourcing `~/.bashrc` and re-prepending the agent-hooks bin to PATH. This recovers login-time PATH setup (Homebrew shellenv, etc.) for bash users without losing the agent-hooks injection that depends on `--rcfile`.
    """)
    func bashrcShimSourcesProfileChainWithIdempotencyGuard() {
        let shim = AgentHookInstaller.bashrcShim()

        // Idempotency guard env var
        #expect(shim.contains("__GRAFTTY_BASH_PROFILE_SOURCED"))
        #expect(shim.contains("export __GRAFTTY_BASH_PROFILE_SOURCED=1"))

        // System profile
        #expect(shim.contains("/etc/profile"))

        // User profile-chain candidates, in order
        #expect(shim.contains(#""$HOME/.bash_profile""#))
        #expect(shim.contains(#""$HOME/.bash_login""#))
        #expect(shim.contains(#""$HOME/.profile""#))

        // Profile chain is sourced BEFORE .bashrc
        let profileGuardIdx = shim.range(of: "__GRAFTTY_BASH_PROFILE_SOURCED")!.lowerBound
        let bashrcSourceIdx = shim.range(of: #"source "$HOME/.bashrc""#)!.lowerBound
        #expect(profileGuardIdx < bashrcSourceIdx)
    }

    @Test func bashLauncherExecsBashWithRcfileFlag() {
        let script = AgentHookInstaller.bashLauncherScript(rcfilePath: "/tmp/test/.bashrc")
        #expect(script.contains("#!/bin/sh"))
        #expect(script.contains(#"exec bash --rcfile '/tmp/test/.bashrc' "$@""#))
    }

    @Test func wrappedUserShellSubstitutesBashOnly() {
        let root = URL(fileURLWithPath: "/test")
        // Bash → substituted with launcher path.
        let bashSubst = AgentHookInstaller.wrappedUserShell("/bin/bash", rootDirectory: root)
        #expect(bashSubst == "/test/bash-init/bash-launcher")
        // zsh / fish / sh / anything else → pass through.
        for shell in ["/bin/zsh", "/usr/local/bin/fish", "/bin/sh", "/bin/dash"] {
            let result = AgentHookInstaller.wrappedUserShell(shell, rootDirectory: root)
            #expect(result == shell)
        }
    }

    @Test func zshrcShimSourcesUserRcAndPrependsAgentBin() {
        let shim = AgentHookInstaller.zshrcShim()
        // Sources user's real .zshrc first.
        #expect(shim.contains(#"source "$HOME/.zshrc""#))
        // Then re-prepends graftty's wrapper bin (after .zshrc has had
        // its say) — gated on GRAFTTY_AGENT_HOOKS_BIN being set.
        #expect(shim.contains("GRAFTTY_AGENT_HOOKS_BIN"))
        #expect(shim.contains(#"export PATH="$GRAFTTY_AGENT_HOOKS_BIN:$PATH""#))
        // Strips an existing occurrence first (idempotent under nested zsh).
        #expect(shim.contains(#"_graftty_path="${_graftty_path//:$GRAFTTY_AGENT_HOOKS_BIN:/:}""#))
    }

    @Test func zshenvProfileLoginShimSourcesUserHome() {
        for basename in [".zshenv", ".zprofile", ".zlogin"] {
            let shim = AgentHookInstaller.zshSourceShim(homeBasename: basename)
            #expect(shim.contains("\"$HOME/\(basename)\""))
            #expect(shim.contains("source"))
        }
    }

    @Test func installRepairsStaleWrapperMarker() throws {
        let root = try Self.temporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stale = bin.appendingPathComponent("claude")
        try "# GRAFTTY_AGENT_HOOK_WRAPPER version=old\n".write(to: stale, atomically: true, encoding: .utf8)

        let installer = AgentHookInstaller(rootDirectory: root, grafttyCLIPath: "/usr/local/bin/graftty")
        let result = try installer.install()
        let repaired = try String(contentsOf: stale, encoding: .utf8)

        #expect(result.writtenFiles.contains(stale))
        #expect(repaired.contains("version=\(AgentHookInstaller.version)"))
        #expect(repaired.contains("graftty team hook claude"))
    }

    @Test func wrapperSearchSkipsGeneratedBinDirectory() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/app/hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/app/graftty",
            codexHomeDirectory: "/app/hooks/codex-home"
        )

        #expect(script.contains(#"if [ "$dir" = '/app/hooks/bin' ]; then"#))
        #expect(script.contains("continue"))
        #expect(script.contains(#"exec "$real_binary" "$@""#))
    }

    @Test func wrapperQuotesShellPathsWithoutExpansion() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/tmp/has $dollar/it's/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/app/graftty",
            codexHomeDirectory: "/tmp/has $dollar/it's/codex-home"
        )

        #expect(script.contains(#"if [ "$dir" = '/tmp/has $dollar/it'"'"'s/bin' ]; then"#))
        // Inline JSON is passed via --settings, single-quoted (with escaped single quotes if any).
        #expect(script.contains(#"--settings '"#))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
