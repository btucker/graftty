import Testing
import Foundation
import Darwin
@testable import GrafttyKit

@Suite("AgentHookInstaller — wrapper script shapes", .serialized)
struct AgentHookInstallerWrapperTests {
    @Test("@spec TEAM-IDLE-1.2: When the Claude wrapper runs with `GRAFTTY_DISABLE_AGENT_HOOKS != 1`, the application shall exec `claude --settings '<inline JSON>'` so graftty's hooks layer additively over the user's settings.")
    func claudeWrapperUsesInlineSettings() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        // Inline JSON includes the three SessionStart/PostToolUse/Stop hook entries.
        #expect(script.contains("--settings"))
        #expect(script.contains("\"SessionStart\""))
        #expect(script.contains("\"PostToolUse\""))
        #expect(script.contains("\"Stop\""))
        #expect(script.contains("graftty team hook claude session-start"))

        // Foreground child: the wrapper keeps a post-runtime cleanup phase.
        #expect(!script.contains("trap"))
        #expect(script.contains("'/usr/local/bin/graftty' team unregister --runtime claude"))

        // No on-disk settings file path is referenced.
        #expect(!script.contains("claude-settings.json"))
    }

    @Test("Claude wrapper falls through to plain claude when GRAFTTY_DISABLE_AGENT_HOOKS=1.")
    func claudeWrapperRespectsDisable() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        #expect(script.contains("GRAFTTY_DISABLE_AGENT_HOOKS"))
        // Both branches run the real binary in the foreground, not as a
        // background child and not via exec.
        #expect(script.contains(#""$real_binary" --settings"#))
        #expect(script.contains(#""$real_binary" "$@""#))
        #expect(!script.contains(" ) &"))
        #expect(!script.contains("exec "))
    }

    @Test("@spec TEAM-IDLE-1.3: Claude wrapper Stop hook spawns the asyncRewake watcher.")
    func claudeWrapperStopIncludesWatcher() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        #expect(script.contains("graftty team hook claude stop"))
        #expect(script.contains("graftty team watch-inbox claude"))
        #expect(script.contains("\"asyncRewake\":true"))
    }

    @Test("Codex wrapper sets CODEX_HOME and runs sync-codex-home before launch.")
    func codexWrapperSetsCodexHome() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        #expect(script.contains("internal sync-codex-home"))
        #expect(script.contains("CODEX_HOME="))
        #expect(script.contains("/Users/x/agent-hooks/codex-home"))
        #expect(!script.contains("trap"))
        #expect(script.contains("'/usr/local/bin/graftty' team unregister --runtime codex"))
    }

    @Test("""
    @spec TEAM-10.4: When the Codex wrapper runs a non-administrative command with agent hooks enabled, the application shall reuse an inherited managed CODEX_HOME without rewriting it from inside the active agent sandbox and shall enable hooks on that managed Codex launch with a launch-scoped override.
    """)
    func codexWrapperReusesInheritedMirrorAndEnablesHooksAtLaunch() throws {
        let run = try runCodexWrapperCommand(
            arguments: ["--version"],
            inheritManagedCodexHome: true
        )

        #expect(run.terminationStatus == 0)
        #expect(!run.didSync)
        #expect(run.forwardedArgs == ["--enable", "hooks", "--version"])
        #expect(run.forwardedCodexHome == run.managedCodexHome)
    }

    @Test("""
    @spec TEAM-10.3: When a wrapped Codex feature, plugin, marketplace, or MCP mutation runs, the application shall execute it against the user's durable Codex home so configuration and cache changes survive managed mirror rebuilds.
    """)
    func codexConfigurationMutationsUseDurableHome() throws {
        let run = try runCodexWrapperCommand(
            arguments: ["plugin", "add", "runpod@runpod"],
            inheritManagedCodexHome: true
        )

        #expect(run.terminationStatus == 0)
        #expect(run.forwardedCodexHome == run.durableCodexHome)
        #expect(run.forwardedArgs == ["plugin", "add", "runpod@runpod"])
    }

    @Test(
        """
        @spec TEAM-10.5: When a wrapped Codex feature, plugin, marketplace, or MCP mutation succeeds, the application shall tell the caller that running Codex sessions must be reloaded before the configuration change is available.
        """,
        arguments: [
            ["plugin", "add", "runpod@runpod"],
            ["plugin", "remove", "runpod@runpod"],
            ["plugin", "marketplace", "add", "https://example.com/plugins.git"],
            ["mcp", "add", "runpod", "--url", "https://mcp.getrunpod.io/"],
            ["--config", "model=\"gpt-5\"", "mcp", "remove", "runpod"],
            ["plugin", "--config", "model=\"gpt-5\"", "add", "runpod@runpod"],
            ["plugin", "marketplace", "--enable", "hooks", "upgrade", "runpod"],
            ["mcp", "--disable=unused", "remove", "runpod"],
            ["features", "enable", "hooks"],
            ["features", "--config", "model=\"gpt-5\"", "disable", "unused"],
        ]
    )
    func successfulCodexConfigurationMutationsPrintReloadGuidance(arguments: [String]) throws {
        let run = try runCodexWrapperCommand(
            arguments: arguments,
            inheritManagedCodexHome: true
        )

        #expect(run.terminationStatus == 0)
        #expect(run.standardError.localizedCaseInsensitiveContains("reload"))
        #expect(run.standardError.localizedCaseInsensitiveContains("new session"))
    }

    @Test("Failed Codex configuration mutations do not print reload guidance.")
    func failedCodexConfigurationMutationDoesNotPrintReloadGuidance() throws {
        let run = try runCodexWrapperCommand(
            arguments: ["plugin", "add", "missing@marketplace"],
            inheritManagedCodexHome: true,
            codexExitStatus: 7
        )

        #expect(run.terminationStatus == 7)
        #expect(!run.standardError.localizedCaseInsensitiveContains("reload"))
    }

    @Test(
        "Successful nonmutating and prompt-like Codex commands do not print reload guidance.",
        arguments: [
            ["plugin", "list"],
            ["plugin", "marketplace", "list"],
            ["mcp", "list"],
            ["--", "plugin", "add", "is prompt text"],
            ["--help", "plugin", "add", "runpod@runpod"],
            ["plugin", "add", "--help"],
            ["mcp", "add", "--help"],
            ["features", "list"],
            ["features", "enable", "--help"],
        ]
    )
    func successfulNonmutatingCodexCommandsDoNotPrintReloadGuidance(arguments: [String]) throws {
        let run = try runCodexWrapperCommand(
            arguments: arguments,
            inheritManagedCodexHome: true
        )

        #expect(run.terminationStatus == 0)
        #expect(!run.standardError.localizedCaseInsensitiveContains("reload"))
    }

    @Test(
        """
        @spec TEAM-10.8: While a wrapped Codex feature, plugin, marketplace, or MCP read command runs, the application shall execute it against the durable Codex home so it observes the latest administrative state.
        """,
        arguments: [
            ["plugin", "list"],
            ["plugin", "marketplace", "list"],
            ["mcp", "list"],
            ["mcp", "get", "runpod"],
            ["features", "list"],
            ["--image=/tmp/image.png", "plugin", "list"],
        ]
    )
    func codexConfigurationAdministrationUsesDurableHome(arguments: [String]) throws {
        let run = try runCodexWrapperCommand(
            arguments: arguments,
            inheritManagedCodexHome: true
        )

        #expect(run.terminationStatus == 0)
        #expect(run.forwardedCodexHome == run.durableCodexHome)
        #expect(run.forwardedArgs == arguments)
    }

    @Test("Disabling agent hooks does not redirect Codex configuration changes into the managed snapshot.")
    func disabledHooksStillUseDurableHomeForConfigurationMutations() throws {
        let run = try runCodexWrapperCommand(
            arguments: ["plugin", "add", "runpod@runpod"],
            inheritManagedCodexHome: true,
            hooksDisabled: true
        )

        #expect(run.terminationStatus == 0)
        #expect(!run.didSync)
        #expect(run.forwardedCodexHome == run.durableCodexHome)
        #expect(!run.forwardedArgs.starts(with: ["--enable", "hooks"]))
    }

    @Test("Disabling hooks preserves an explicit custom CODEX_HOME for Codex administration.")
    func disabledHooksPreserveCustomCodexHomeForAdministration() throws {
        let run = try runCodexWrapperCommand(
            arguments: ["plugin", "list"],
            inheritManagedCodexHome: false,
            hooksDisabled: true,
            inheritCustomCodexHome: true
        )

        #expect(run.terminationStatus == 0)
        #expect(!run.didSync)
        #expect(run.forwardedCodexHome.hasSuffix("/custom-codex-home"))
        #expect(run.forwardedCodexHome != run.durableCodexHome)
    }

    @Test("A failed mirror sync warns but still launches Codex against the durable home.")
    func failedCodexMirrorSyncFallsBackToDurableHome() throws {
        let run = try runCodexWrapperCommand(
            arguments: ["--version"],
            inheritManagedCodexHome: false,
            syncExitStatus: 13
        )

        #expect(run.terminationStatus == 0)
        #expect(run.didSync)
        #expect(run.forwardedCodexHome == run.durableCodexHome)
        #expect(run.standardError.contains("starting without Graftty's managed hook configuration"))
    }

    @Test("Codex wrapper starts an app-server, registers metadata, runs remote TUI, and cleans up.")
    func codexWrapperStartsAppServerAndRegistersMetadata() throws {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        #expect(script.contains(#"_graftty_codex_socket_dir="${TMPDIR:-/tmp}/graftty-codex-app-server""#))
        #expect(script.contains(#"_graftty_codex_socket="$_graftty_codex_socket_dir/$$.sock""#))
        #expect(script.contains(#"_graftty_codex_app_server_log="$_graftty_codex_socket_dir/$$.log""#))
        #expect(script.contains(#"_graftty_codex_should_use_app_server() {"#))
        #expect(script.contains(#"while [ "$#" -gt 0 ]; do"#))
        #expect(script.contains(#"--help|-h|--version|-V)"#))
        #expect(script.contains(#"--remote|--remote=*)"#))
        #expect(script.contains(#"-i|--image)"#))
        #expect(script.contains(#"-c|--config|--enable|--disable|--model|-m|--profile|-p|--sandbox|-s|--ask-for-approval|-a|--approval-policy|--cwd|--cd|-C|--color|--output-schema|--origin|--settings|--remote-auth-token-env|--local-provider|--add-dir)"#))
        #expect(script.contains(#"app-server|remote-control|exec|e|review|login|logout|mcp|plugin|mcp-server|app|completion|update|doctor|sandbox|debug|apply|a|archive|delete|unarchive|cloud|exec-server|features|help)"#))
        #expect(script.contains(#"if ! _graftty_codex_should_use_app_server "$@"; then"#))
        #expect(script.contains(#"env CODEX_HOME="$_graftty_codex_runtime_home" "$real_binary" --enable hooks "$@""#))
        #expect(script.contains(#"env CODEX_HOME="$_graftty_codex_runtime_home" "$real_binary" --enable hooks app-server --listen "unix://$_graftty_codex_socket" </dev/null >>"$_graftty_codex_app_server_log" 2>&1 &"#))
        #expect(script.contains(#"_graftty_codex_app_server_pid=$!"#))
        #expect(script.contains(#"_graftty_wait_for_codex_socket() {"#))
        #expect(script.contains(#"[ -S "$_graftty_codex_socket" ]"#))
        #expect(script.contains(#"kill -0 "$_graftty_codex_app_server_pid""#))
        #expect(script.contains(#"team codex-app-server register --socket "$_graftty_codex_socket" --real-binary "$real_binary" --app-server-pid "$_graftty_codex_app_server_pid""#))
        #expect(script.contains(#"env CODEX_HOME="$_graftty_codex_runtime_home" "$real_binary" --enable hooks --remote "unix://$_graftty_codex_socket" "$@""#))
        #expect(script.contains(#"team codex-app-server unregister --socket "$_graftty_codex_socket" --app-server-pid "$_graftty_codex_app_server_pid""#))
        #expect(script.contains(#"kill "$_graftty_codex_app_server_pid""#))
        #expect(script.contains("_graftty_codex_shutdown_wait_count=0"))
        #expect(script.contains(#"kill -KILL "$_graftty_codex_app_server_pid""#))
        #expect(script.contains(#"wait "$_graftty_codex_app_server_pid""#))
        #expect(script.contains(#"rm -f "$_graftty_codex_socket""#))

        let failureBranchStart = try #require(script.range(of: #"if ! _graftty_wait_for_codex_socket; then"#))
        let failureBranchEnd = try #require(script.range(
            of: #"team codex-app-server register"#,
            range: failureBranchStart.upperBound..<script.endIndex
        ))
        let failureBranch = script[failureBranchStart.lowerBound..<failureBranchEnd.lowerBound]
        let preserveIdx = try #require(failureBranch.range(of: "_graftty_preserve_codex_app_server_log=1")?.lowerBound)
        let cleanupIdx = try #require(failureBranch.range(of: "cleanup_after_runtime")?.lowerBound)
        let exitIdx = try #require(failureBranch.range(of: "exit 1")?.lowerBound)
        #expect(preserveIdx < cleanupIdx)
        #expect(cleanupIdx < exitIdx)
        #expect(script.contains("'/usr/local/bin/graftty' team unregister --runtime codex"))
        #expect(script.contains(#"if [ -z "${_graftty_preserve_codex_app_server_log:-}" ] && [ -n "${_graftty_codex_app_server_log:-}" ]; then"#))
    }

    @Test(
        "@spec TEAM-PRESENCE-1.3: When the graftty wrapper launches an agent runtime, the wrapper shall register a PID whose lifetime covers the foreground runtime process, not the short-lived registration helper PID.",
        arguments: [TeamHookRuntime.claude, .codex]
    )
    func wrapperRegistersRuntimeLifetimePIDBeforeLaunch(runtime: TeamHookRuntime) {
        let script = AgentHookInstaller.wrapperScript(
            runtime: runtime,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: runtime.rawValue,
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        #expect(script.contains(
            #"'/usr/local/bin/graftty' team register --runtime \#(runtime.rawValue) --pid "$$" >/dev/null 2>&1 || true"#
        ))
        #expect(script.contains("cleanup_after_runtime"))

        let registerIdx = script.range(of: "team register --runtime")!.lowerBound
        let runtimeIdx = script.range(
            of: #""$real_binary""#,
            range: registerIdx..<script.endIndex
        )!.lowerBound
        #expect(registerIdx < runtimeIdx)
    }

    @Test("Wrapper launches the runtime in the foreground.")
    func wrapperLaunchesRuntimeInForeground() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        #expect(!script.contains("agent_pid=$!"))
        #expect(!script.contains(#"wait "$agent_pid""#))
        #expect(!script.contains("forward_signal()"))
        #expect(!script.contains(" ) &"))
        #expect(!script.contains(#"exec env CODEX_HOME="#))
        #expect(script.contains(#"env CODEX_HOME="#))
        #expect(script.contains(#""$real_binary" "$@""#))
    }

    @Test("Wrapper runtime launch shape includes hooks arguments.")
    func wrapperRuntimeLaunchShapeIncludesHookArguments() {
        let claude = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        let codex = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        #expect(claude.contains(#""$real_binary" --settings"#))
        #expect(claude.contains(#""$real_binary" "$@""#))
        #expect(codex.contains(#"env CODEX_HOME="#))
        #expect(codex.contains(#""$real_binary" "$@""#))
    }

    @Test("Generated wrapper registers its own PID while the runtime is running.")
    func wrapperRegistersOwnPIDWhileRuntimeIsRunning() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = root.appendingPathComponent("wrapper-bin", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)

        let childPIDFile = root.appendingPathComponent("child.pid")
        let remoteStartedFile = root.appendingPathComponent("remote-started")
        let remoteStopFile = root.appendingPathComponent("remote-stop")
        let fakeGraftty = root.appendingPathComponent("graftty")
        try writeExecutable(
            """
            #!/bin/sh
            if [ "$1" = "team" ] && [ "$2" = "register" ]; then
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--pid" ]; then
                  shift
                  printf '%s\\n' "$1" > "$GRAFTTY_TEST_PID_FILE"
                  exit 0
                fi
                shift
              done
            fi
            exit 0
            """,
            to: fakeGraftty
        )

        try writeExecutable(
            fakeCodexScript(remoteBody: """
            printf 'started\\n' > "$GRAFTTY_TEST_REMOTE_STARTED_FILE"
            while [ ! -f "$GRAFTTY_TEST_REMOTE_STOP_FILE" ]; do
              sleep 0.05
            done
            exit 0
            """),
            to: realDirectory.appendingPathComponent("codex")
        )

        let wrapper = wrapperDirectory.appendingPathComponent("codex")
        try writeExecutable(
            AgentHookInstaller.wrapperScript(
                runtime: .codex,
                wrapperDirectory: wrapperDirectory.path,
                realCommandName: "codex",
                grafttyCLIPath: fakeGraftty.path,
                codexHomeDirectory: root.appendingPathComponent("codex-home", isDirectory: true).path
            ),
            to: wrapper
        )

        let process = Process()
        process.executableURL = wrapper
        process.arguments = ["30"]
        process.environment = [
            "PATH": "\(wrapperDirectory.path):\(realDirectory.path):/bin:/usr/bin",
            "GRAFTTY_TEST_PID_FILE": childPIDFile.path,
            "GRAFTTY_TEST_REMOTE_STARTED_FILE": remoteStartedFile.path,
            "GRAFTTY_TEST_REMOTE_STOP_FILE": remoteStopFile.path,
        ]
        try process.run()
        defer {
            if process.isRunning {
                try? Data("stop\n".utf8).write(to: remoteStopFile, options: .atomic)
                _ = waitUntil(timeout: 2.0) {
                    !process.isRunning
                }
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let registeredPIDString = try #require(waitForFileContents(childPIDFile, timeout: 2.0))
        let registeredPID = (registeredPIDString.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).intValue
        _ = try #require(waitForFileContents(remoteStartedFile, timeout: 2.0))
        #expect(registeredPID == process.processIdentifier)
        #expect(process.isRunning)
    }

    @Test("Generated Codex wrapper preserves terminal stdin for the runtime child.")
    func codexWrapperRuntimeChildKeepsTerminalStdin() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = root.appendingPathComponent("wrapper-bin", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)

        let fakeGraftty = root.appendingPathComponent("graftty")
        try writeExecutable(
            """
            #!/bin/sh
            exit 0
            """,
            to: fakeGraftty
        )

        let realCodex = realDirectory.appendingPathComponent("codex")
        try writeExecutable(
            fakeCodexScript(remoteBody: """
            if [ -t 0 ]; then
              printf 'GRAFTTY_STDIN_TTY:yes\\n'
            else
              printf 'GRAFTTY_STDIN_TTY:no\\n'
            fi
            """),
            to: realCodex
        )

        let wrapper = wrapperDirectory.appendingPathComponent("codex")
        try writeExecutable(
            AgentHookInstaller.wrapperScript(
                runtime: .codex,
                wrapperDirectory: wrapperDirectory.path,
                realCommandName: "codex",
                grafttyCLIPath: fakeGraftty.path,
                codexHomeDirectory: root.appendingPathComponent("codex-home", isDirectory: true).path
            ),
            to: wrapper
        )

        let spawned = try PtyProcess.spawn(
            argv: [wrapper.path],
            env: [
                "PATH": "\(wrapperDirectory.path):\(realDirectory.path):/bin:/usr/bin",
                "TERM": "xterm-256color",
            ],
            initialSize: (cols: 80, rows: 24)
        )
        defer {
            Darwin.kill(spawned.pid, SIGKILL)
            Darwin.close(spawned.masterFD)
        }

        let output = readFromPTY(spawned.masterFD, until: "GRAFTTY_STDIN_TTY:", timeout: 2.0)
        #expect(output.contains("GRAFTTY_STDIN_TTY:yes"), "runtime child lost terminal stdin; output: \(output)")
    }

    @Test(
        """
        @spec TEAM-10.2: If a codex invocation names a non-interactive subcommand, requests help or version output, or supplies its own `--remote` endpoint, then the generated wrapper shall run codex directly without starting an app-server.
        """,
        arguments: [
            ["-c", "model=gpt-5", "exec", "prompt"],
            ["-C", "/repo", "exec", "prompt"],
            ["-a", "never", "exec", "prompt"],
            ["--enable", "some-feature", "review"],
            ["--disable=some-feature", "mcp", "list"],
            ["--remote-auth-token-env", "TOKEN", "doctor"],
            ["--add-dir", "/tmp/extra", "apply"],
            ["--image=/tmp/image.png", "review"],
            ["--image", "/tmp/image.png", "--help"],
            ["--help"],
            ["--version"],
            ["--remote", "unix:///tmp/external.sock"],
            ["--remote=unix:///tmp/external.sock"],
            ["review"],
            ["e", "prompt"],
            ["mcp", "list"],
            ["plugin", "list"],
            ["mcp-server"],
            ["app"],
            ["update"],
            ["doctor"],
            ["sandbox"],
            ["debug"],
            ["apply"],
            ["a"],
            ["archive", "thread-1"],
            ["delete", "thread-1"],
            ["unarchive", "thread-1"],
            ["cloud"],
            ["exec-server"],
            ["features"],
            ["help"],
        ]
    )
    func codexWrapperBypassesAppServerForNonInteractiveSubcommands(arguments: [String]) throws {
        let run = try runCodexWrapperClassifier(arguments)
        #expect(run.terminationStatus == 0)
        #expect(run.mode == "direct")
        #expect(run.forwardedArgs == arguments)
    }

    @Test(
        """
        @spec TEAM-10.1: When codex is invoked interactively — any option flags (known or unknown to the wrapper), a prompt, or arguments after `--` — the generated wrapper shall start a codex app-server and connect the TUI to it via `--remote`, so team-message delivery has a live app-server for the session.
        """,
        arguments: [
            ["--model", "gpt-5"],
            ["--yolo"],
            ["--full-auto"],
            ["--unknown-option"],
            ["--yolo", "--unknown-option", "a prompt"],
            ["--image", "/tmp/image.png", "review"],
            ["-i", "/tmp/image.png", "plugin", "list"],
            ["--image", "/tmp/image.png", "mcp", "list"],
            ["--image", "/tmp/image.png", "features", "list"],
            ["--", "review"],
        ]
    )
    func codexWrapperUsesAppServerForFlagLedInteractiveInvocations(arguments: [String]) throws {
        let run = try runCodexWrapperClassifier(arguments)
        #expect(run.terminationStatus == 0)
        #expect(run.mode == "remote")
        #expect(run.forwardedArgs == arguments)
    }

    @Test(
        "Generated Codex wrapper uses app-server for interactive resume and fork invocations.",
        arguments: [
            ["resume"],
            ["fork", "--last"],
        ]
    )
    func codexWrapperUsesAppServerForInteractiveSubcommands(arguments: [String]) throws {
        let run = try runCodexWrapperClassifier(arguments)
        #expect(run.terminationStatus == 0)
        #expect(run.mode == "remote")
        #expect(run.forwardedArgs == arguments)
    }

    @Test("Generated wrapper preserves runtime exit status after cleanup.")
    func wrapperPreservesRuntimeExitStatusAfterCleanup() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = root.appendingPathComponent("wrapper-bin", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)

        let fakeGraftty = root.appendingPathComponent("graftty")
        try writeExecutable(
            """
            #!/bin/sh
            exit 0
            """,
            to: fakeGraftty
        )

        let realCodex = realDirectory.appendingPathComponent("codex")
        try writeExecutable(
            fakeCodexScript(remoteBody: "exit 37"),
            to: realCodex
        )

        let wrapper = wrapperDirectory.appendingPathComponent("codex")
        try writeExecutable(
            AgentHookInstaller.wrapperScript(
                runtime: .codex,
                wrapperDirectory: wrapperDirectory.path,
                realCommandName: "codex",
                grafttyCLIPath: fakeGraftty.path,
                codexHomeDirectory: root.appendingPathComponent("codex-home", isDirectory: true).path
            ),
            to: wrapper
        )

        let process = Process()
        process.executableURL = wrapper
        process.environment = [
            "PATH": "\(wrapperDirectory.path):\(realDirectory.path):/bin:/usr/bin",
            "TERM": "xterm-256color",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 37)
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-wrapper-signal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
    }

    /// Shared harness for the classifier tests: installs a generated codex
    /// wrapper alongside a fake codex, runs the wrapper with `arguments`,
    /// and returns the mode the fake recorded ("remote" when the wrapper
    /// injected its own app-server `--remote`, "direct" otherwise) plus the
    /// argv the fake received. Args are recorded one per line so a
    /// word-splitting regression is visible even for arguments containing
    /// spaces.
    private func runCodexWrapperClassifier(
        _ arguments: [String]
    ) throws -> (terminationStatus: Int32, mode: String, forwardedArgs: [String]) {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = root.appendingPathComponent("wrapper-bin", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)

        let fakeGraftty = root.appendingPathComponent("graftty")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: fakeGraftty)

        let modeFile = root.appendingPathComponent("mode")
        let argsFile = root.appendingPathComponent("args")
        try writeExecutable(
            fakeCodexScript(remoteBody: """
            printf '%s\\n' "$GRAFTTY_FAKE_CODEX_MODE" > "$GRAFTTY_TEST_MODE_FILE"
            printf '%s\\n' "$@" > "$GRAFTTY_TEST_ARGS_FILE"
            exit 0
            """),
            to: realDirectory.appendingPathComponent("codex")
        )

        let wrapper = wrapperDirectory.appendingPathComponent("codex")
        try writeExecutable(
            AgentHookInstaller.wrapperScript(
                runtime: .codex,
                wrapperDirectory: wrapperDirectory.path,
                realCommandName: "codex",
                grafttyCLIPath: fakeGraftty.path,
                codexHomeDirectory: root.appendingPathComponent("codex-home", isDirectory: true).path
            ),
            to: wrapper
        )

        let process = Process()
        process.executableURL = wrapper
        process.arguments = arguments
        process.environment = [
            "PATH": "\(wrapperDirectory.path):\(realDirectory.path):/bin:/usr/bin",
            "GRAFTTY_TEST_MODE_FILE": modeFile.path,
            "GRAFTTY_TEST_ARGS_FILE": argsFile.path,
        ]
        try process.run()
        process.waitUntilExit()

        let mode = try String(contentsOf: modeFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var forwardedArgs = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if forwardedArgs.last == "" {
            forwardedArgs.removeLast()
        }
        return (process.terminationStatus, mode, forwardedArgs)
    }

    private func runCodexWrapperCommand(
        arguments: [String],
        inheritManagedCodexHome: Bool,
        codexExitStatus: Int32 = 0,
        syncExitStatus: Int32 = 0,
        hooksDisabled: Bool = false,
        inheritCustomCodexHome: Bool = false
    ) throws -> (
        terminationStatus: Int32,
        forwardedArgs: [String],
        forwardedCodexHome: String,
        managedCodexHome: String,
        durableCodexHome: String,
        standardError: String,
        didSync: Bool
    ) {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = root.appendingPathComponent("wrapper-bin", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real-bin", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let codexSource = root.appendingPathComponent("durable-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSource, withIntermediateDirectories: true)

        let syncMarker = root.appendingPathComponent("did-sync")
        let fakeGraftty = root.appendingPathComponent("graftty")
        try writeExecutable(
            """
            #!/bin/sh
            if [ "$1" = "internal" ] && [ "$2" = "sync-codex-home" ]; then
              printf 'sync\\n' > "$GRAFTTY_TEST_SYNC_MARKER"
              exit "$GRAFTTY_TEST_SYNC_EXIT_STATUS"
            fi
            exit 0
            """,
            to: fakeGraftty
        )

        let argsFile = root.appendingPathComponent("args")
        let codexHomeFile = root.appendingPathComponent("forwarded-codex-home")
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' "${CODEX_HOME:-}" > "$GRAFTTY_TEST_CODEX_HOME_FILE"
            if [ "$1" = "--enable" ] && [ "$2" = "hooks" ] && [ "$3" = "app-server" ]; then
              shift 3
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--listen" ]; then
                  shift
                  socket="${1#unix://}"
                  break
                fi
                shift
              done
              nc -lU "$socket" >/dev/null 2>&1 &
              nc_pid=$!
              trap 'kill "$nc_pid" 2>/dev/null || true; rm -f "$socket"; exit 0' TERM INT
              wait "$nc_pid"
              exit $?
            fi
            printf '%s\\n' "$@" > "$GRAFTTY_TEST_ARGS_FILE"
            exit "$GRAFTTY_TEST_CODEX_EXIT_STATUS"
            """,
            to: realDirectory.appendingPathComponent("codex")
        )

        let wrapper = wrapperDirectory.appendingPathComponent("codex")
        try writeExecutable(
            AgentHookInstaller.wrapperScript(
                runtime: .codex,
                wrapperDirectory: wrapperDirectory.path,
                realCommandName: "codex",
                grafttyCLIPath: fakeGraftty.path,
                codexHomeDirectory: codexHome.path,
                codexSourceDirectory: codexSource.path
            ),
            to: wrapper
        )

        let process = Process()
        process.executableURL = wrapper
        process.arguments = arguments
        var environment = [
            "PATH": "\(wrapperDirectory.path):\(realDirectory.path):/bin:/usr/bin",
            "GRAFTTY_TEST_ARGS_FILE": argsFile.path,
            "GRAFTTY_TEST_CODEX_HOME_FILE": codexHomeFile.path,
            "GRAFTTY_TEST_SYNC_MARKER": syncMarker.path,
            "GRAFTTY_TEST_SYNC_EXIT_STATUS": String(syncExitStatus),
            "GRAFTTY_TEST_CODEX_EXIT_STATUS": String(codexExitStatus),
        ]
        if inheritManagedCodexHome {
            environment["CODEX_HOME"] = codexHome.path
        } else if inheritCustomCodexHome {
            environment["CODEX_HOME"] = root.appendingPathComponent("custom-codex-home").path
        }
        if hooksDisabled {
            environment["GRAFTTY_DISABLE_AGENT_HOOKS"] = "1"
        }
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        var forwardedArgs = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if forwardedArgs.last == "" {
            forwardedArgs.removeLast()
        }
        let standardError = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (
            process.terminationStatus,
            forwardedArgs,
            try String(contentsOf: codexHomeFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            codexHome.path,
            codexSource.path,
            standardError,
            FileManager.default.fileExists(atPath: syncMarker.path)
        )
    }

    private func fakeCodexScript(remoteBody: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--enable" ] && [ "$2" = "hooks" ]; then
          shift 2
        fi
        if [ "$1" = "app-server" ]; then
          shift
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--listen" ]; then
              shift
              socket="${1#unix://}"
              break
            fi
            shift
          done
          nc -lU "$socket" >/dev/null 2>&1 &
          nc_pid=$!
          trap 'kill "$nc_pid" 2>/dev/null || true; rm -f "$socket"; exit 0' TERM INT
          wait "$nc_pid"
          exit $?
        fi
        GRAFTTY_FAKE_CODEX_MODE=direct
        if [ "$1" = "--remote" ]; then
          case "$2" in
            unix://*graftty-codex-app-server*)
              shift 2
              GRAFTTY_FAKE_CODEX_MODE=remote
              ;;
          esac
        fi
        export GRAFTTY_FAKE_CODEX_MODE
        \(remoteBody)
        """
    }

    private func waitForFileContents(_ url: URL, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty {
                return value
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate()
    }

    private func readFromPTY(_ fd: Int32, until marker: String, timeout: TimeInterval) -> String {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var output = ""
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = buffer.withUnsafeMutableBufferPointer {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if count > 0 {
                output += String(bytes: buffer.prefix(count), encoding: .utf8) ?? ""
                if output.contains(marker) { return output }
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return output
    }
}
