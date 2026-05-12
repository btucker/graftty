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

        var env = launcher.subprocessEnv(from: processEnv)
        env.removeValue(forKey: "GRAFTTY_AGENT_HOOKS_BIN")
        env.removeValue(forKey: "ZDOTDIR")
        env.removeValue(forKey: "GHOSTTY_ZSH_ZDOTDIR")
        env["GRAFTTY_SOCK"] = socketPath
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

        let userShell = hooksEnabled
            ? AgentHookInstaller.wrappedUserShell(rawUserShell, rootDirectory: agentHooksRoot)
            : rawUserShell

        if let ghosttyResourcesDir, !ghosttyResourcesDir.isEmpty,
           (rawUserShell as NSString).lastPathComponent == "zsh" {
            env["ZDOTDIR"] = (ghosttyResourcesDir as NSString)
                .appendingPathComponent("shell-integration/zsh")
            if hooksEnabled {
                env["GHOSTTY_ZSH_ZDOTDIR"] = AgentHookInstaller
                    .zshInitDirectory(rootDirectory: agentHooksRoot)
                    .path
            }
        }

        return ZmxSpawnConfiguration(
            sessionName: sessionName,
            argv: launcher.attachArgv(sessionName: sessionName, userShell: userShell),
            env: env,
            workingDirectory: URL(fileURLWithPath: worktreePath, isDirectory: true)
        )
    }

    private static func applyTerminalCapabilities(
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
