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

    @Test func loginSpawnPositionalShellReturnsNilExceptForBashWithHooks() {
        let root = URL(fileURLWithPath: "/test")
        let bashLauncher = AgentHookInstaller.bashLauncherPath(rootDirectory: root).path

        // Bash with hooks enabled → returns launcher path.
        #expect(AgentHookInstaller.loginSpawnPositionalShell(
            rawUserShell: "/bin/bash",
            hooksEnabled: true,
            rootDirectory: root
        ) == bashLauncher)
        #expect(AgentHookInstaller.loginSpawnPositionalShell(
            rawUserShell: "/opt/homebrew/bin/bash",
            hooksEnabled: true,
            rootDirectory: root
        ) == bashLauncher)

        // Bash with hooks disabled → nil (let zmx do its default login spawn).
        #expect(AgentHookInstaller.loginSpawnPositionalShell(
            rawUserShell: "/bin/bash",
            hooksEnabled: false,
            rootDirectory: root
        ) == nil)

        // Non-bash shells → always nil regardless of hooks.
        for shell in ["/bin/zsh", "/usr/local/bin/fish", "/bin/sh", "/bin/dash"] {
            for hooks in [true, false] {
                #expect(AgentHookInstaller.loginSpawnPositionalShell(
                    rawUserShell: shell,
                    hooksEnabled: hooks,
                    rootDirectory: root
                ) == nil)
            }
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

    @Test func zshenvProfileShimSourcesUserHome() {
        for basename in [".zshenv", ".zprofile"] {
            let shim = AgentHookInstaller.zshSourceShim(homeBasename: basename)
            #expect(shim.contains("\"$HOME/\(basename)\""))
            #expect(shim.contains("source"))
        }
    }

    @Test("""
    @spec ZMX-6.8: When the host-managed `zmx attach` spawn invokes zsh as a login shell with agent hooks enabled, the application shall install a `_graftty_prepend_wrapper_path` precmd hook that strips any existing `$GRAFTTY_AGENT_HOOKS_BIN` occurrence from `$PATH` and re-prepends a fresh one before every prompt. The hook shall be registered first from the `.zshrc` shim (after sourcing `~/.zshrc`) and re-registered from the `.zlogin` shim (after sourcing `~/.zlogin`) using a strip-then-append pattern, so the hook appears exactly once in `precmd_functions` and runs after any hooks the user's shell init registered. Without this, sourcing the user's `~/.zlogin` (which conventionally loads tools like RVM that prepend gem/ruby paths to `$PATH` at source-time) pushes graftty's wrapper bin off position 1, allowing user-installed `claude` / `codex` binaries in `~/.local/bin` / `~/.bun/bin` / etc. to shadow the wrapper if any user-prepended directory ever contained those names. The before-every-prompt re-prepend also defends against any chpwd / precmd-driven PATH-management tool (asdf, mise, nvm-on-cd, etc.) the user's shell init registers — those would otherwise override a one-shot `.zshrc` prepend.
    """)
    func zloginShimReregistersPrecmdHookAfterUserZlogin() {
        let zshrc = AgentHookInstaller.zshrcShim()
        let zlogin = AgentHookInstaller.zloginShim()

        for shim in [zshrc, zlogin] {
            #expect(shim.contains("_graftty_prepend_wrapper_path"))
            // Idempotency: strip first so re-sourcing the shim doesn't
            // duplicate the hook in precmd_functions.
            #expect(shim.contains("precmd_functions[@]:#_graftty_prepend_wrapper_path"))
            #expect(shim.contains("precmd_functions+=(_graftty_prepend_wrapper_path)"))
        }

        // .zlogin re-registers AFTER sourcing the user's .zlogin so any
        // precmd / chpwd hooks the user's init added are positioned ahead
        // of ours in precmd_functions and ours fires last each prompt.
        let userZloginIdx = zlogin.range(of: #"source "$HOME/.zlogin""#)!.lowerBound
        let hookRegisterIdx = zlogin.range(of: "precmd_functions+=(_graftty_prepend_wrapper_path)")!.lowerBound
        #expect(userZloginIdx < hookRegisterIdx)
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
        #expect(script.contains(#""$real_binary" "$@""#))
        #expect(!script.contains(#"exec "$real_binary" "$@""#))
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

    @Test("""
    @spec AGENT-6.11: While provider plugins are enabled, the application shall remove its managed Claude wrapper, leave lifecycle hooks and team instructions to the installed plugins, retain only Codex's app-server/remote transport wrapper, and preserve legacy wrapper hook injection when plugin mode is disabled.
    """)
    func providerPluginModeRemovesClaudeWrapperAndKeepsCodexTransport() throws {
        let root = try Self.temporaryDirectory()
        _ = try AgentHookInstaller(
            rootDirectory: root,
            grafttyCLIPath: "/app/graftty"
        ).install()
        let claudeURL = root.appendingPathComponent("bin/claude")
        let codexURL = root.appendingPathComponent("bin/codex")
        #expect(FileManager.default.fileExists(atPath: claudeURL.path))

        _ = try AgentHookInstaller(
            rootDirectory: root,
            grafttyCLIPath: "/app/graftty",
            providerPluginsEnabled: true
        ).install()
        let codex = try String(contentsOf: codexURL, encoding: .utf8)

        #expect(!FileManager.default.fileExists(atPath: claudeURL.path))
        #expect(codex.contains("GRAFTTY_PROVIDER_PLUGINS=1"))
        #expect(codex.contains("app-server --listen"))
        #expect(codex.contains(#"--remote "unix://$_graftty_codex_socket""#))
    }

    @Test("The wrapper mints a runtime-prefixed canonical agent ID that team register accepts.")
    func wrapperMintsValidCanonicalAgentID() {
        for runtime in [TeamHookRuntime.codex, .claude] {
            let script = AgentHookInstaller.wrapperScript(
                runtime: runtime,
                wrapperDirectory: "/app/hooks/bin",
                realCommandName: runtime.rawValue,
                grafttyCLIPath: "/app/graftty",
                codexHomeDirectory: "/app/hooks/codex-home"
            )
            #expect(script.contains(
                #"GRAFTTY_AGENT_ID=""# + runtime.rawValue + #"-$_graftty_agent_suffix""#
            ))
            #expect(!script.contains("(runtime.rawValue)"))
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
