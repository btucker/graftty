import Foundation
import Testing
@testable import GrafttyKit

@Suite("ZmxSpawnConfiguration — pure logic")
struct ZmxSpawnConfigurationTests {
    private let paneSessionID = PaneSessionID(id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!)
    private let launcher = ZmxLauncher(
        executable: URL(fileURLWithPath: "/tmp/zmx"),
        zmxDir: URL(fileURLWithPath: "/tmp/zmx-dir", isDirectory: true)
    )
    private let bundleURL = URL(fileURLWithPath: "/Applications/Graftty.app", isDirectory: true)
    private let ghosttyResourcesDir = "/Applications/Ghostty.app/Contents/Resources/ghostty"
    private let agentHooksRoot = URL(fileURLWithPath: "/tmp/hooks", isDirectory: true)

    @Test("""
    @spec ZMX-6.2: The `GRAFTTY_SOCK` environment variable shall continue to be set in the spawned shell's environment per `ATTN-2.4`. For zmx-backed native panes, this shall be passed in the host-managed `zmx attach` process environment rather than relying on libghostty surface-spawn env.
    """)
    func buildsAttachArgvForWrappedShellAndRequiredEnv() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin",
            "ZMX_SESSION": "old",
        ])

        #expect(config.sessionName == "graftty-deadbeef")
        #expect(config.argv.first == "/tmp/zmx")
        #expect(Array(config.argv[1...2]) == ["attach", "graftty-deadbeef"])
        #expect(config.argv.count == 3)
        #expect(config.env["SHELL"] == "/bin/zsh")
        #expect(config.env["ZMX_DIR"] == "/tmp/zmx-dir")
        #expect(config.env["GRAFTTY_SOCK"] == "/tmp/graftty.sock")
        #expect(config.env["ZMX_SESSION"] == nil)
        #expect(config.workingDirectory.path == "/repo/wt")
    }

    @Test("""
    @spec ZMX-6.3: If `GHOSTTY_RESOURCES_DIR` is set (per `CONFIG-2.1`) and the user's shell basename is `zsh`, the host-managed `zmx attach` environment shall set `ZDOTDIR=<ghostty-resources>/shell-integration/zsh` so the inner shell zmx spawns sources Ghostty's zsh integration directly. Without this env construction, precmd hooks do not run, no OSC 7 / OSC 133 sequences are emitted, and `PWD-x.x`, the default-command first-PWD trigger, and shell-integration-driven attention badges go silent.
    """)
    func zshWithGhosttyResourcesSetsIntegrationEnvAndHookZDOTDIR() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin",
        ])

        #expect(config.env["ZDOTDIR"] == "\(ghosttyResourcesDir)/shell-integration/zsh")
        #expect(config.env["GHOSTTY_ZSH_ZDOTDIR"] == AgentHookInstaller.zshInitDirectory(rootDirectory: agentHooksRoot).path)
    }

    @Test func enabledHooksPrependHookBinToSanitizedPath() throws {
        let inputPath = "\(bundleURL.path)/Contents/MacOS:/usr/bin"
        let config = makeConfig(processEnv: [
            "SHELL": "/bin/zsh",
            "PATH": inputPath,
        ])
        let hookBin = AgentHookInstaller.binDirectory(rootDirectory: agentHooksRoot).path
        let sanitizedPath = BundlePathSanitizer.sanitized(currentPath: inputPath, bundleURL: bundleURL)

        #expect(config.env["GRAFTTY_AGENT_HOOKS_BIN"] == hookBin)
        #expect(config.env["PATH"] == "\(hookBin):\(sanitizedPath)")
    }

    @Test func disabledHooksOmitHookEnvAndPathUsesSanitizedPath() throws {
        let config = makeConfig(
            processEnv: [
                "SHELL": "/bin/bash",
                "PATH": "\(bundleURL.path)/Contents/MacOS:/usr/bin",
            ],
            agentHooksDisabled: true
        )
        let sanitizedPath = BundlePathSanitizer.sanitized(
            currentPath: "\(bundleURL.path)/Contents/MacOS:/usr/bin",
            bundleURL: bundleURL
        )

        #expect(config.env["GRAFTTY_AGENT_HOOKS_BIN"] == nil)
        #expect(config.env["GHOSTTY_ZSH_ZDOTDIR"] == nil)
        #expect(config.env["PATH"] == sanitizedPath)
    }

    @Test("""
    @spec ZMX-6.4: When agent hooks are enabled for a zsh shell, the host-managed `zmx attach` environment shall set `GHOSTTY_ZSH_ZDOTDIR` to Graftty's agent-hook zsh init directory so Ghostty's zsh integration can restore that directory after loading. When hooks are disabled, `GHOSTTY_ZSH_ZDOTDIR` shall be omitted.
    """)
    func disabledHooksReplaceInheritedZDOTDIRAndRemoveAgentHookEnv() throws {
        let config = makeConfig(
            processEnv: staleHookEnv(shell: "/bin/zsh"),
            agentHooksDisabled: true
        )

        #expect(config.env["GRAFTTY_AGENT_HOOKS_BIN"] == nil)
        #expect(config.env["ZDOTDIR"] == "\(ghosttyResourcesDir)/shell-integration/zsh")
        #expect(config.env["GHOSTTY_ZSH_ZDOTDIR"] == nil)
    }

    @Test func missingGhosttyResourcesOmitZshIntegrationEnv() throws {
        let config = makeConfig(
            processEnv: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin",
            ],
            ghosttyResourcesDir: nil
        )

        #expect(config.env["ZDOTDIR"] == nil)
        #expect(config.env["GHOSTTY_ZSH_ZDOTDIR"] == nil)
    }

    @Test func missingGhosttyResourcesRemoveInheritedZshIntegrationEnv() throws {
        let config = makeConfig(
            processEnv: staleHookEnv(shell: "/bin/zsh"),
            ghosttyResourcesDir: nil
        )

        #expect(config.env["ZDOTDIR"] == nil)
        #expect(config.env["GHOSTTY_ZSH_ZDOTDIR"] == nil)
    }

    @Test func nonZshShellRemovesInheritedZshIntegrationEnv() throws {
        let config = makeConfig(processEnv: staleHookEnv(shell: "/bin/bash"))

        #expect(config.env["ZDOTDIR"] == nil)
        #expect(config.env["GHOSTTY_ZSH_ZDOTDIR"] == nil)
    }

    @Test func zmxSessionIsStrippedFromSpawnEnvironment() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/bin/sh",
            "PATH": "/usr/bin",
            "ZMX_SESSION": "parent-session",
        ])

        #expect(config.env["ZMX_SESSION"] == nil)
    }

    @Test("""
    @spec ZMX-6.5: Host-managed native panes shall synthesize terminal capability environment for the `zmx attach` child when launched from a macOS GUI process that lacks terminal env vars. If Ghostty terminfo is available next to `GHOSTTY_RESOURCES_DIR`, the env shall match Ghostty's local-shell defaults closely enough for color-aware tools such as Claude Code to enable color output.
    """)
    func missingTerminalEnvUsesGhosttyCapabilitiesWhenTerminfoIsAvailable() throws {
        let root = try makeGhosttyResourcesFixture(hasTerminfo: true)
        let config = makeConfig(
            processEnv: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin",
            ],
            ghosttyResourcesDir: root.appendingPathComponent("ghostty").path
        )

        #expect(config.env["TERM"] == "xterm-ghostty")
        #expect(config.env["TERMINFO"] == root.appendingPathComponent("terminfo").path)
        #expect(config.env["COLORTERM"] == "truecolor")
        #expect(config.env["TERM_PROGRAM"] == "ghostty")
    }

    @Test func missingGhosttyTerminfoFallsBackToWidelyAvailableTerm() throws {
        let config = makeConfig(
            processEnv: [
                "SHELL": "/bin/sh",
                "PATH": "/usr/bin",
            ],
            ghosttyResourcesDir: nil
        )

        #expect(config.env["TERM"] == "xterm-256color")
        #expect(config.env["TERMINFO"] == nil)
        #expect(config.env["COLORTERM"] == "truecolor")
        #expect(config.env["TERM_PROGRAM"] == "ghostty")
    }

    @Test func existingTerminalCapabilityEnvWins() throws {
        let root = try makeGhosttyResourcesFixture(hasTerminfo: true)
        let config = makeConfig(
            processEnv: [
                "SHELL": "/bin/sh",
                "PATH": "/usr/bin",
                "TERM": "screen-256color",
                "TERMINFO": "/custom/terminfo",
                "COLORTERM": "24bit",
                "TERM_PROGRAM": "CustomTerminal",
            ],
            ghosttyResourcesDir: root.appendingPathComponent("ghostty").path
        )

        #expect(config.env["TERM"] == "screen-256color")
        #expect(config.env["TERMINFO"] == "/custom/terminfo")
        #expect(config.env["COLORTERM"] == "24bit")
        #expect(config.env["TERM_PROGRAM"] == "CustomTerminal")
    }

    private func makeConfig(
        processEnv: [String: String],
        ghosttyResourcesDir: String? = "/Applications/Ghostty.app/Contents/Resources/ghostty",
        agentHooksDisabled: Bool = false
    ) -> ZmxSpawnConfiguration {
        ZmxSpawnConfiguration.make(
            launcher: launcher,
            paneSessionID: paneSessionID,
            worktreePath: "/repo/wt",
            socketPath: "/tmp/graftty.sock",
            processEnv: processEnv,
            bundleURL: bundleURL,
            ghosttyResourcesDir: ghosttyResourcesDir,
            agentHooksDisabled: agentHooksDisabled,
            agentHooksRoot: agentHooksRoot
        )
    }

    private func makeGhosttyResourcesFixture(hasTerminfo: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-ghostty-resources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ghostty"),
            withIntermediateDirectories: true
        )
        if hasTerminfo {
            let terminfoDir = root.appendingPathComponent("terminfo/78")
            try FileManager.default.createDirectory(at: terminfoDir, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: terminfoDir.appendingPathComponent("xterm-ghostty").path,
                contents: Data()
            )
        }
        return root
    }

    private func staleHookEnv(shell: String) -> [String: String] {
        [
            "SHELL": shell,
            "PATH": "/usr/bin",
            "GRAFTTY_AGENT_HOOKS_BIN": "/stale/hooks/bin",
            "ZDOTDIR": "/stale/zdotdir",
            "GHOSTTY_ZSH_ZDOTDIR": "/stale/ghostty-zdotdir",
        ]
    }
}

@Suite("""
@spec ZMX-6.6: When the host-managed `zmx attach` spawn invokes the user's shell, the spawn shall recover login-shell behavior. For non-bash shells (and bash with agent hooks disabled), the argv shall omit the positional shell argument so zmx applies its documented default of spawning `$SHELL` as a login shell, with `env["SHELL"]` set to the resolved user-shell path. For bash with agent hooks enabled (per ZMX-6.7), the spawn shall keep the positional pointing at the bash launcher script because login bash discards `--rcfile`. This restores `~/.zprofile` (via the ZMX-6.3 ZDOTDIR shim for zsh) processing — without it, `eval "$(brew shellenv)"` is skipped and `~/.zshrc` references to Homebrew-installed binaries (rbenv, nvm, etc.) resolve to "command not found", cascading into broken keybindings, missing colors, and shell-init errors.
""")
struct ZmxLoginShellRecoveryTests {
    private let paneSessionID = PaneSessionID(id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!)
    private let launcher = ZmxLauncher(
        executable: URL(fileURLWithPath: "/tmp/zmx"),
        zmxDir: URL(fileURLWithPath: "/tmp/zmx-dir", isDirectory: true)
    )
    private let bundleURL = URL(fileURLWithPath: "/Applications/Graftty.app", isDirectory: true)
    private let agentHooksRoot = URL(fileURLWithPath: "/tmp/hooks", isDirectory: true)

    @Test func zshDropsPositionalShellAndSetsShellEnv() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin",
        ])

        #expect(config.argv == ["/tmp/zmx", "attach", "graftty-deadbeef"])
        #expect(config.env["SHELL"] == "/bin/zsh")
    }

    @Test func bashWithoutHooksDropsPositionalShell() throws {
        let config = makeConfig(
            processEnv: [
                "SHELL": "/bin/bash",
                "PATH": "/usr/bin",
            ],
            agentHooksDisabled: true
        )

        #expect(config.argv == ["/tmp/zmx", "attach", "graftty-deadbeef"])
        #expect(config.env["SHELL"] == "/bin/bash")
    }

    @Test func bashWithHooksKeepsPositionalLauncher() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/opt/homebrew/bin/bash",
            "PATH": "/usr/bin",
        ])

        let expectedLauncher = AgentHookInstaller.wrappedUserShell("/opt/homebrew/bin/bash", rootDirectory: agentHooksRoot)
        #expect(config.argv.count == 4)
        #expect(config.argv.last == expectedLauncher)
        #expect(config.env["SHELL"] == "/opt/homebrew/bin/bash")
    }

    private func makeConfig(
        processEnv: [String: String],
        ghosttyResourcesDir: String? = "/Applications/Ghostty.app/Contents/Resources/ghostty",
        agentHooksDisabled: Bool = false
    ) -> ZmxSpawnConfiguration {
        ZmxSpawnConfiguration.make(
            launcher: launcher,
            paneSessionID: paneSessionID,
            worktreePath: "/repo/wt",
            socketPath: "/tmp/graftty.sock",
            processEnv: processEnv,
            bundleURL: bundleURL,
            ghosttyResourcesDir: ghosttyResourcesDir,
            agentHooksDisabled: agentHooksDisabled,
            agentHooksRoot: agentHooksRoot
        )
    }
}
