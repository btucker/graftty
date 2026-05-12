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
        paneID: UUID,
        worktreePath: String,
        socketPath: String,
        processEnv: [String: String],
        bundleURL: URL,
        ghosttyResourcesDir: String?,
        agentHooksDisabled: Bool,
        agentHooksRoot: URL
    ) -> ZmxSpawnConfiguration {
        let sessionName = launcher.sessionName(for: paneID)
        let rawUserShell = processEnv["SHELL"] ?? "/bin/sh"
        let hooksEnabled = !agentHooksDisabled

        var env = launcher.subprocessEnv(from: processEnv)
        env.removeValue(forKey: "GRAFTTY_AGENT_HOOKS_BIN")
        env.removeValue(forKey: "ZDOTDIR")
        env.removeValue(forKey: "GHOSTTY_ZSH_ZDOTDIR")
        env["GRAFTTY_SOCK"] = socketPath

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

        if hooksEnabled,
           let ghosttyResourcesDir, !ghosttyResourcesDir.isEmpty,
           (rawUserShell as NSString).lastPathComponent == "zsh" {
            env["ZDOTDIR"] = (ghosttyResourcesDir as NSString)
                .appendingPathComponent("shell-integration/zsh")
            env["GHOSTTY_ZSH_ZDOTDIR"] = AgentHookInstaller
                .zshInitDirectory(rootDirectory: agentHooksRoot)
                .path
        }

        return ZmxSpawnConfiguration(
            sessionName: sessionName,
            argv: launcher.attachArgv(sessionName: sessionName, userShell: userShell),
            env: env,
            workingDirectory: URL(fileURLWithPath: worktreePath, isDirectory: true)
        )
    }
}
