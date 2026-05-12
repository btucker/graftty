import Foundation
import Testing
@testable import GrafttyKit

@Suite("ZmxSpawnConfiguration — pure logic")
struct ZmxSpawnConfigurationTests {
    private let paneID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!
    private let launcher = ZmxLauncher(
        executable: URL(fileURLWithPath: "/tmp/zmx"),
        zmxDir: URL(fileURLWithPath: "/tmp/zmx-dir", isDirectory: true)
    )
    private let bundleURL = URL(fileURLWithPath: "/Applications/Graftty.app", isDirectory: true)
    private let ghosttyResourcesDir = "/Applications/Ghostty.app/Contents/Resources/ghostty"
    private let agentHooksRoot = URL(fileURLWithPath: "/tmp/hooks", isDirectory: true)

    @Test func buildsAttachArgvForWrappedShellAndRequiredEnv() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin",
            "ZMX_SESSION": "old",
        ])

        #expect(config.sessionName == "graftty-deadbeef")
        #expect(config.argv.first == "/tmp/zmx")
        #expect(Array(config.argv[1...2]) == ["attach", "graftty-deadbeef"])
        #expect(config.argv.last == "/bin/zsh")
        #expect(config.env["ZMX_DIR"] == "/tmp/zmx-dir")
        #expect(config.env["GRAFTTY_SOCK"] == "/tmp/graftty.sock")
        #expect(config.env["ZMX_SESSION"] == nil)
        #expect(config.workingDirectory.path == "/repo/wt")
    }

    @Test func zshWithGhosttyResourcesSetsIntegrationEnvAndHookZDOTDIR() throws {
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

    @Test func bashUsesAgentHookWrappedShellWhenHooksAreEnabled() throws {
        let config = makeConfig(processEnv: [
            "SHELL": "/opt/homebrew/bin/bash",
            "PATH": "/usr/bin",
        ])

        #expect(config.argv.last == AgentHookInstaller.wrappedUserShell("/opt/homebrew/bin/bash", rootDirectory: agentHooksRoot))
    }

    @Test func disabledHooksUseRawShellAndDoNotSetHookEnv() throws {
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

        #expect(config.argv.last == "/bin/bash")
        #expect(config.env["GRAFTTY_AGENT_HOOKS_BIN"] == nil)
        #expect(config.env["GHOSTTY_ZSH_ZDOTDIR"] == nil)
        #expect(config.env["PATH"] == sanitizedPath)
    }

    @Test func disabledHooksReplaceInheritedZDOTDIRAndRemoveAgentHookEnv() throws {
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

    private func makeConfig(
        processEnv: [String: String],
        ghosttyResourcesDir: String? = "/Applications/Ghostty.app/Contents/Resources/ghostty",
        agentHooksDisabled: Bool = false
    ) -> ZmxSpawnConfiguration {
        ZmxSpawnConfiguration.make(
            launcher: launcher,
            paneID: paneID,
            worktreePath: "/repo/wt",
            socketPath: "/tmp/graftty.sock",
            processEnv: processEnv,
            bundleURL: bundleURL,
            ghosttyResourcesDir: ghosttyResourcesDir,
            agentHooksDisabled: agentHooksDisabled,
            agentHooksRoot: agentHooksRoot
        )
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
