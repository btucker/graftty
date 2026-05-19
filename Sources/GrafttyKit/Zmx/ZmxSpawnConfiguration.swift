import Foundation

/// Structured parameters for spawning the short-lived native `zmx attach`
/// client that backs a host-managed terminal surface.
public struct ZmxSpawnConfiguration: Sendable, Equatable {
    public let sessionName: String
    public let argv: [String]
    public let env: [String: String]
    public let workingDirectory: URL

    public static func make(
        launcher: ZmxLauncher,
        paneSessionID: PaneSessionID,
        worktreePath: String,
        socketPath: String,
        processEnv: [String: String],
        bundleURL: URL,
        ghosttyResourcesDir: String?,
        agentHooksDisabled: Bool,
        agentHooksRoot: URL
    ) -> ZmxSpawnConfiguration {
        let sessionName = launcher.sessionName(for: paneSessionID)
        let rawUserShell = processEnv["SHELL"] ?? "/bin/sh"
        let hooksEnabled = !agentHooksDisabled
        let shellBasename = (rawUserShell as NSString).lastPathComponent

        var env = launcher.subprocessEnv(from: processEnv)
        env.removeValue(forKey: "GRAFTTY_AGENT_HOOKS_BIN")
        env.removeValue(forKey: "ZDOTDIR")
        env.removeValue(forKey: "GHOSTTY_ZSH_ZDOTDIR")
        env["GRAFTTY_SOCK"] = socketPath
        // ZMX-6.6: zmx's no-command default-login-spawn reads $SHELL from
        // its env to decide what binary to exec. Set it explicitly so the
        // resolved user shell is used regardless of what the parent
        // process inherited.
        env["SHELL"] = rawUserShell
        applyTerminalCapabilities(
            env: &env,
            ghosttyResourcesDir: ghosttyResourcesDir
        )

        let sanitizedPath = BundlePathSanitizer.sanitized(
            currentPath: processEnv["PATH"] ?? "",
            bundleURL: bundleURL
        )
        if hooksEnabled {
            let hookBin = AgentHookInstaller.binDirectory(rootDirectory: agentHooksRoot).path
            env["GRAFTTY_AGENT_HOOKS_BIN"] = hookBin
            env["PATH"] = "\(hookBin):\(sanitizedPath)"
        } else {
            env["PATH"] = sanitizedPath
        }

        applyZshShellIntegration(
            env: &env,
            userShellPath: rawUserShell,
            ghosttyResourcesDir: ghosttyResourcesDir
        )
        if hooksEnabled, shellBasename == "zsh", env["ZDOTDIR"] != nil {
            env["GHOSTTY_ZSH_ZDOTDIR"] = AgentHookInstaller
                .zshInitDirectory(rootDirectory: agentHooksRoot)
                .path
        }

        // ZMX-6.6/6.7: For non-bash shells (and bash with hooks disabled),
        // omit the positional shell argument so zmx's documented default
        // applies — it spawns $SHELL as a login shell, which sources the
        // profile chain (~/.zprofile, ~/.bash_profile) before the rc file.
        // For bash-with-hooks, keep the positional pointing at the launcher
        // script because login bash discards `--rcfile`.
        let argv: [String]
        if let wrappedShell = AgentHookInstaller.loginSpawnPositionalShell(
            rawUserShell: rawUserShell,
            hooksEnabled: hooksEnabled,
            rootDirectory: agentHooksRoot
        ) {
            argv = launcher.attachArgv(sessionName: sessionName, userShell: wrappedShell)
        } else {
            argv = launcher.attachArgv(sessionName: sessionName)
        }

        return ZmxSpawnConfiguration(
            sessionName: sessionName,
            argv: argv,
            env: env,
            workingDirectory: URL(fileURLWithPath: worktreePath, isDirectory: true)
        )
    }

    /// Apply the terminal-capability env (TERM, COLORTERM, TERM_PROGRAM,
    /// TERMINFO when ghostty-terminfo is available) so the inner shell
    /// emits truecolor and unlocks ghostty-specific terminfo features.
    /// Shared between the host-managed pane path (`make`) and the WebSocket
    /// bridge (`WebSession.start`) so whichever `zmx attach` wins the
    /// create-session race produces a shell with identical terminal
    /// capabilities — WEB-4.10.
    static func applyTerminalCapabilities(
        env: inout [String: String],
        ghosttyResourcesDir: String?
    ) {
        let terminfoDir = ghosttyResourcesDir.flatMap(availableGhosttyTerminfoDir)
        setDefault("TERM", in: &env, to: terminfoDir == nil ? "xterm-256color" : "xterm-ghostty")
        setDefault("COLORTERM", in: &env, to: "truecolor")
        setDefault("TERM_PROGRAM", in: &env, to: "ghostty")

        if let terminfoDir {
            setDefault("TERMINFO", in: &env, to: terminfoDir.path)
        }
    }

    /// Apply Ghostty's zsh shell-integration env. Sets `ZDOTDIR` to
    /// ghostty's `shell-integration/zsh` dir so the spawned zsh sources
    /// ghostty's prompt hooks — which emit OSC 7 (PWD) and OSC 133 (prompt
    /// marks). Without those, `TerminalManager`'s `onShellReady` callback
    /// never fires, the `maybeRunDefaultCommand` flow never types the
    /// user's configured command, and shell-integration attention pings
    /// stay silent.
    ///
    /// Shared between the host-managed pane path (`make`) and the
    /// WebSocket bridge (`WebSession.start`) — the bridge needs it because
    /// its `zmx attach` can win the create-session race against the
    /// matching host pane's attach (the host pane spends seconds inside
    /// `git worktree add` before its attach starts). WEB-4.10.
    static func applyZshShellIntegration(
        env: inout [String: String],
        userShellPath: String,
        ghosttyResourcesDir: String?
    ) {
        guard let ghosttyResourcesDir, !ghosttyResourcesDir.isEmpty else { return }
        let shellBasename = (userShellPath as NSString).lastPathComponent
        guard shellBasename == "zsh" else { return }
        env["ZDOTDIR"] = (ghosttyResourcesDir as NSString)
            .appendingPathComponent("shell-integration/zsh")
    }

    private static func setDefault(_ key: String, in env: inout [String: String], to value: String) {
        guard env[key]?.isEmpty ?? true else { return }
        env[key] = value
    }

    private static func availableGhosttyTerminfoDir(from resourcesDir: String) -> URL? {
        let resourcesURL = URL(fileURLWithPath: resourcesDir, isDirectory: true)
        let terminfoURL = resourcesURL
            .deletingLastPathComponent()
            .appendingPathComponent("terminfo", isDirectory: true)
        let compiledEntry = terminfoURL
            .appendingPathComponent("78", isDirectory: true)
            .appendingPathComponent("xterm-ghostty")
        let sourceEntry = terminfoURL.appendingPathComponent("ghostty.terminfo")

        guard FileManager.default.fileExists(atPath: compiledEntry.path)
            || FileManager.default.fileExists(atPath: sourceEntry.path) else {
            return nil
        }
        return terminfoURL
    }
}
