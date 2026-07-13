import Foundation

public struct AgentHookInstallResult: Sendable, Equatable {
    public let writtenFiles: [URL]

    public init(writtenFiles: [URL]) {
        self.writtenFiles = writtenFiles
    }
}

public struct AgentHookInstaller: Sendable {
    public static let version = "1"

    public let rootDirectory: URL
    public let grafttyCLIPath: String

    public init(rootDirectory: URL, grafttyCLIPath: String) {
        self.rootDirectory = rootDirectory
        self.grafttyCLIPath = grafttyCLIPath
    }

    public static func rootDirectory(defaultDirectory: URL = AppState.defaultDirectory) -> URL {
        defaultDirectory.appendingPathComponent("agent-hooks", isDirectory: true)
    }

    public static func binDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    public var binDirectory: URL {
        Self.binDirectory(rootDirectory: rootDirectory)
    }

    public static func zshInitDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("zsh-init", isDirectory: true)
    }

    public var zshInitDirectory: URL {
        Self.zshInitDirectory(rootDirectory: rootDirectory)
    }

    public static func bashInitDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("bash-init", isDirectory: true)
    }

    public var bashInitDirectory: URL {
        Self.bashInitDirectory(rootDirectory: rootDirectory)
    }

    /// Path to the launcher script graftty hands zmx as the userShell
    /// when the user's `$SHELL` is bash. The launcher exec's bash with
    /// `--rcfile <bash-init>/.bashrc` so bash reads our shim instead of
    /// `~/.bashrc` directly. The shim sources `~/.bashrc` first and then
    /// re-prepends the wrapper bin — same model as the zsh ZDOTDIR
    /// approach. Bash has no env-var equivalent of ZDOTDIR; only the
    /// `--rcfile` CLI flag, hence the launcher script.
    public static func bashLauncherPath(rootDirectory: URL) -> URL {
        bashInitDirectory(rootDirectory: rootDirectory)
            .appendingPathComponent("bash-launcher")
    }

    /// If `originalShell`'s basename is `bash`, return the bash launcher
    /// path so zmx attaches with our wrapper. Otherwise pass through.
    /// Other shells (zsh: ZDOTDIR; fish/sh: not yet supported) are
    /// handled elsewhere or fall back to the surface-env PATH prepend.
    public static func wrappedUserShell(_ originalShell: String, rootDirectory: URL) -> String {
        guard (originalShell as NSString).lastPathComponent == "bash" else {
            return originalShell
        }
        return bashLauncherPath(rootDirectory: rootDirectory).path
    }

    /// Returns the launcher path for callers that need an explicit
    /// positional shell, OR `nil` if the spawn should let zmx apply
    /// its documented default of spawning `$SHELL` as a login shell.
    ///
    /// Returns the launcher path (per `wrappedUserShell`) only when the
    /// user's shell is bash AND agent hooks are enabled — that's the
    /// one case where login mode would discard `--rcfile` and break
    /// the agent-hooks shim. ZMX-6.6, ZMX-6.7.
    public static func loginSpawnPositionalShell(
        rawUserShell: String,
        hooksEnabled: Bool,
        rootDirectory: URL
    ) -> String? {
        let basename = (rawUserShell as NSString).lastPathComponent
        guard basename == "bash", hooksEnabled else { return nil }
        return wrappedUserShell(rawUserShell, rootDirectory: rootDirectory)
    }

    public func install() throws -> AgentHookInstallResult {
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        var written: [URL] = []
        let claudeWrapper = binDirectory.appendingPathComponent("claude")
        let codexWrapper = binDirectory.appendingPathComponent("codex")
        let codexHomeDirectory = binDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("codex-home", isDirectory: true)
            .path

        try writeIfChanged(
            AgentHookInstaller.wrapperScript(
                runtime: .claude,
                wrapperDirectory: binDirectory.path,
                realCommandName: "claude",
                grafttyCLIPath: grafttyCLIPath,
                codexHomeDirectory: codexHomeDirectory
            ),
            to: claudeWrapper,
            executable: true,
            written: &written
        )
        try writeIfChanged(
            AgentHookInstaller.wrapperScript(
                runtime: .codex,
                wrapperDirectory: binDirectory.path,
                realCommandName: "codex",
                grafttyCLIPath: grafttyCLIPath,
                codexHomeDirectory: codexHomeDirectory
            ),
            to: codexWrapper,
            executable: true,
            written: &written
        )

        try installZshInitShim(written: &written)
        try installBashInitShim(written: &written)

        return AgentHookInstallResult(writtenFiles: written)
    }

    /// Writes the ZDOTDIR shim files (`.zshenv`, `.zprofile`, `.zshrc`,
    /// `.zlogin`) under `zshInitDirectory`. Surface launches set
    /// `ZDOTDIR` to that path so zsh reads our `.zshrc` instead of the
    /// home one. Our `.zshrc` sources the user's real `.zshrc` first, then
    /// re-prepends the wrapper bin to PATH — defending against user
    /// shell-init `export PATH="<dir>:$PATH"` lines that would otherwise
    /// push graftty's bin behind `~/.bun/bin`, `~/.local/bin`, etc.,
    /// causing `claude` / `codex` to resolve to the unwrapped binaries.
    private func installZshInitShim(written: inout [URL]) throws {
        try FileManager.default.createDirectory(at: zshInitDirectory, withIntermediateDirectories: true)

        // .zshenv / .zprofile / .zlogin: zsh skips home versions when
        // ZDOTDIR is set, so the shim files have to source them
        // explicitly to preserve user behavior.
        for (basename, homeBasename) in [
            (".zshenv", ".zshenv"),
            (".zprofile", ".zprofile"),
        ] {
            try writeIfChanged(
                Self.zshSourceShim(homeBasename: homeBasename),
                to: zshInitDirectory.appendingPathComponent(basename),
                executable: false,
                written: &written
            )
        }

        // .zshrc: source user's real .zshrc, then re-prepend our wrapper
        // bin (idempotent under nested zsh).
        try writeIfChanged(
            Self.zshrcShim(),
            to: zshInitDirectory.appendingPathComponent(".zshrc"),
            executable: false,
            written: &written
        )

        try writeIfChanged(
            Self.zloginShim(),
            to: zshInitDirectory.appendingPathComponent(".zlogin"),
            executable: false,
            written: &written
        )
    }

    static func zshSourceShim(homeBasename: String) -> String {
        """
        # Generated by graftty AgentHookInstaller. Sourced by zsh because
        # `ZDOTDIR` points at the graftty agent-hooks zsh-init directory,
        # which causes zsh to skip the user's home equivalent. Source it
        # explicitly so user behavior is preserved.
        [ -r "$HOME/\(homeBasename)" ] && source "$HOME/\(homeBasename)"
        """
    }

    /// Bash analog of `installZshInitShim`. Bash has no ZDOTDIR-style
    /// env-var redirect, so we install a launcher script that exec's
    /// bash with `--rcfile <shim>` and substitute that launcher for the
    /// user's bash path when handing the shell name to zmx attach.
    private func installBashInitShim(written: inout [URL]) throws {
        try FileManager.default.createDirectory(at: bashInitDirectory, withIntermediateDirectories: true)

        let rcfilePath = bashInitDirectory.appendingPathComponent(".bashrc")
        try writeIfChanged(
            Self.bashrcShim(),
            to: rcfilePath,
            executable: false,
            written: &written
        )

        try writeIfChanged(
            Self.bashLauncherScript(rcfilePath: rcfilePath.path),
            to: bashInitDirectory.appendingPathComponent("bash-launcher"),
            executable: true,
            written: &written
        )
    }

    static func bashrcShim() -> String {
        """
        # Generated by graftty AgentHookInstaller. The launcher script (per
        # ZMX-6.7) invokes bash with `--rcfile <this-file>` so that:
        #   1. The agent-hooks shim runs in non-login mode (login bash
        #      discards --rcfile).
        #   2. We can re-prepend graftty's wrapper bin to PATH after the
        #      user's shell-init has had its say, so `claude` / `codex`
        #      resolve to our wrapper rather than the upstream installs in
        #      `~/.bun/bin` / `~/.local/bin` / etc.
        #
        # But non-login bash skips the profile chain (~/.bash_profile etc.)
        # which on a typical macOS install is where `eval "$(brew shellenv)"`
        # lands. Source it ourselves once per environment, gated by
        # `__GRAFTTY_BASH_PROFILE_SOURCED` so nested non-login bash
        # invocations don't re-source.
        if [ -z "$__GRAFTTY_BASH_PROFILE_SOURCED" ]; then
            export __GRAFTTY_BASH_PROFILE_SOURCED=1
            [ -r /etc/profile ] && . /etc/profile
            for _graftty_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                if [ -r "$_graftty_profile" ]; then
                    . "$_graftty_profile"
                    break
                fi
            done
            unset _graftty_profile
        fi

        [ -r "$HOME/.bashrc" ] && source "$HOME/.bashrc"

        if [ -n "$GRAFTTY_AGENT_HOOKS_BIN" ]; then
            # Strip any existing occurrences of our bin so nested bash
            # invocations don't accumulate duplicates.
            case ":$PATH:" in
                *":$GRAFTTY_AGENT_HOOKS_BIN:"*)
                    _graftty_path=":$PATH:"
                    _graftty_path="${_graftty_path//:$GRAFTTY_AGENT_HOOKS_BIN:/:}"
                    _graftty_path="${_graftty_path#:}"
                    _graftty_path="${_graftty_path%:}"
                    PATH="$_graftty_path"
                    unset _graftty_path
                    ;;
            esac
            export PATH="$GRAFTTY_AGENT_HOOKS_BIN:$PATH"
        fi
        """
    }

    static func bashLauncherScript(rcfilePath: String) -> String {
        """
        #!/bin/sh
        # Generated by graftty AgentHookInstaller. Invoked as the
        # userShell argument to `zmx attach` when the user's $SHELL is
        # bash, so the spawned bash gets `--rcfile <shim>` pointing at
        # the graftty-managed shim that re-prepends the wrapper bin
        # after the user's .bashrc has had its say.
        exec bash --rcfile \(shellLiteral(rcfilePath)) "$@"
        """
    }

    static func zshrcShim() -> String {
        """
        # Generated by graftty AgentHookInstaller. Source the user's real
        # .zshrc first so any user PATH manipulations run; then re-prepend
        # graftty's wrapper bin so `claude` / `codex` resolve to our
        # wrapper rather than the upstream installations in
        # `~/.bun/bin` / `~/.local/bin` / etc.
        [ -r "$HOME/.zshrc" ] && source "$HOME/.zshrc"

        if [ -n "$GRAFTTY_AGENT_HOOKS_BIN" ]; then
            # Strip any existing occurrences of our bin so nested zsh
            # invocations don't accumulate duplicates.
            case ":$PATH:" in
                *":$GRAFTTY_AGENT_HOOKS_BIN:"*)
                    local _graftty_path=":$PATH:"
                    _graftty_path="${_graftty_path//:$GRAFTTY_AGENT_HOOKS_BIN:/:}"
                    _graftty_path="${_graftty_path#:}"
                    _graftty_path="${_graftty_path%:}"
                    PATH="$_graftty_path"
                    unset _graftty_path
                    ;;
            esac
            export PATH="$GRAFTTY_AGENT_HOOKS_BIN:$PATH"
        fi

        \(precmdHookSnippet())
        """
    }

    /// Sources `~/.zlogin` (where RVM is conventionally loaded), then
    /// re-registers `precmdHookSnippet` so our precmd hook is positioned
    /// behind any precmd / chpwd hooks the user's `.zlogin` added. ZMX-6.8.
    static func zloginShim() -> String {
        zshSourceShim(homeBasename: ".zlogin") + "\n\n" + precmdHookSnippet()
    }

    /// Inline zsh that (re-)installs `_graftty_prepend_wrapper_path` at the
    /// END of `precmd_functions` via strip-then-append. Embedded in both
    /// `zshrcShim` and `zloginShim`: the `.zshrc` copy handles interactive
    /// non-login zsh; the `.zlogin` copy reorders the hook behind any user
    /// `.zlogin`-registered hooks so ours fires last each prompt. ZMX-6.8.
    private static func precmdHookSnippet() -> String {
        """
        # ZMX-6.8: keep graftty's wrapper bin at PATH position 1 across
        # every prompt by re-prepending in a precmd hook. Strip-then-append
        # keeps a single entry in precmd_functions and lets .zlogin reorder
        # us behind user-init hooks (asdf, mise, nvm-on-cd, etc.).
        _graftty_prepend_wrapper_path() {
            [ -z "$GRAFTTY_AGENT_HOOKS_BIN" ] && return
            case ":$PATH:" in
                *":$GRAFTTY_AGENT_HOOKS_BIN:"*)
                    local _gp=":$PATH:"
                    _gp="${_gp//:$GRAFTTY_AGENT_HOOKS_BIN:/:}"
                    _gp="${_gp#:}"
                    _gp="${_gp%:}"
                    PATH="$_gp"
                    ;;
            esac
            export PATH="$GRAFTTY_AGENT_HOOKS_BIN:$PATH"
        }
        typeset -ga precmd_functions
        precmd_functions=(${precmd_functions[@]:#_graftty_prepend_wrapper_path})
        precmd_functions+=(_graftty_prepend_wrapper_path)
        """
    }

    public static func wrapperScript(
        runtime: TeamHookRuntime,
        wrapperDirectory: String,
        realCommandName: String,
        grafttyCLIPath: String,
        codexHomeDirectory: String
    ) -> String {
        let resolveBlock = realBinaryResolutionShell(
            wrapperDirectory: wrapperDirectory,
            realCommandName: realCommandName
        )
        let registerBlock = """
        # Register this wrapper PID before launching the runtime. The runtime
        # remains a foreground child in the same process group so TUIs keep
        # normal terminal semantics, while the wrapper gets a short teardown
        # phase after the runtime exits.
        \(shellCommandToken(grafttyCLIPath)) team register --runtime \(runtime.rawValue) --pid "$$" >/dev/null 2>&1 || true
        """

        let codexCleanupBlock: String
        if runtime == .codex {
            codexCleanupBlock = """
              if [ -n "${_graftty_codex_socket:-}" ] && [ -n "${_graftty_codex_app_server_pid:-}" ]; then
                \(shellCommandToken(grafttyCLIPath)) team codex-app-server unregister --socket "$_graftty_codex_socket" --app-server-pid "$_graftty_codex_app_server_pid" >/dev/null 2>&1 || true
              fi
              if [ -n "${_graftty_codex_app_server_pid:-}" ]; then
                kill "$_graftty_codex_app_server_pid" 2>/dev/null || true
                _graftty_codex_shutdown_wait_count=0
                while kill -0 "$_graftty_codex_app_server_pid" 2>/dev/null; do
                  if [ "$_graftty_codex_shutdown_wait_count" -ge 20 ]; then
                    kill -KILL "$_graftty_codex_app_server_pid" 2>/dev/null || true
                    break
                  fi
                  sleep 0.1
                  _graftty_codex_shutdown_wait_count=$((_graftty_codex_shutdown_wait_count + 1))
                done
                wait "$_graftty_codex_app_server_pid" 2>/dev/null || true
                unset _graftty_codex_shutdown_wait_count
              fi
              if [ -n "${_graftty_codex_socket:-}" ]; then
                rm -f "$_graftty_codex_socket"
              fi
              if [ -z "${_graftty_preserve_codex_app_server_log:-}" ] && [ -n "${_graftty_codex_app_server_log:-}" ]; then
                rm -f "$_graftty_codex_app_server_log"
              fi
            """
        } else {
            codexCleanupBlock = ""
        }

        let cleanupBlock = """
        cleanup_after_runtime() {
          # Some TUIs issue terminal capability queries during startup/shutdown.
          # A late reply can otherwise land in the parent shell after the TUI
          # exits (for example Kitty keyboard protocol replies like CSI ? ... u).
          # Drain only a tiny, immediately-pending window and restore tty state.
          if [ -t 0 ] && command -v stty >/dev/null 2>&1 && command -v dd >/dev/null 2>&1; then
            _graftty_stty="$(stty -g 2>/dev/null)" || _graftty_stty=""
            if [ -n "$_graftty_stty" ] && stty -icanon -echo min 0 time 1 2>/dev/null; then
              dd bs=1024 count=1 of=/dev/null 2>/dev/null || true
              stty "$_graftty_stty" 2>/dev/null || true
            fi
          fi
          \(shellCommandToken(grafttyCLIPath)) team unregister --runtime \(runtime.rawValue) 2>/dev/null || true
        \(codexCleanupBlock)
        }
        """

        let runtimeBlock: String
        switch runtime {
        case .claude:
            let inlineJSON = claudeInlineSettingsJSON(grafttyCLIPath: grafttyCLIPath)
            let escapedJSON = shellLiteral(inlineJSON)
            runtimeBlock = """
            if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
              "$real_binary" --settings \(escapedJSON) "$@"
            else
              "$real_binary" "$@"
            fi
            """
        case .codex:
            let codexHomeLiteral = shellLiteral(codexHomeDirectory)
            runtimeBlock = """
            if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
              \(shellCommandToken(grafttyCLIPath)) internal sync-codex-home
              _graftty_codex_should_use_app_server() {
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    --help|-h|--version|-V)
                      return 1
                      ;;
                    --remote|--remote=*)
                      return 1
                      ;;
                    -c|--config|--enable|--disable|--model|-m|--profile|-p|--sandbox|-s|--ask-for-approval|-a|--approval-policy|--cwd|--cd|-C|--color|--output-schema|--origin|--settings|--remote-auth-token-env|--local-provider|--add-dir|-i|--image)
                      shift
                      [ "$#" -gt 0 ] && shift
                      continue
                      ;;
                    --)
                      return 0
                      ;;
                    -*)
                      shift
                      continue
                      ;;
                    app-server|remote-control|exec|e|review|login|logout|mcp|plugin|mcp-server|app|completion|update|doctor|sandbox|debug|apply|a|archive|delete|unarchive|cloud|exec-server|features|help)
                      return 1
                      ;;
                    *)
                      return 0
                      ;;
                  esac
                done
                return 0
              }
              if ! _graftty_codex_should_use_app_server "$@"; then
                env CODEX_HOME=\(codexHomeLiteral) "$real_binary" "$@"
              else
              _graftty_codex_socket_dir="${TMPDIR:-/tmp}/graftty-codex-app-server"
              mkdir -p "$_graftty_codex_socket_dir"
              _graftty_codex_socket="$_graftty_codex_socket_dir/$$.sock"
              _graftty_codex_app_server_log="$_graftty_codex_socket_dir/$$.log"
              rm -f "$_graftty_codex_socket" "$_graftty_codex_app_server_log"
              env CODEX_HOME=\(codexHomeLiteral) "$real_binary" app-server --listen "unix://$_graftty_codex_socket" </dev/null >>"$_graftty_codex_app_server_log" 2>&1 &
              _graftty_codex_app_server_pid=$!
              _graftty_wait_for_codex_socket() {
                _graftty_wait_count=0
                while [ "$_graftty_wait_count" -lt 50 ]; do
                  if [ -S "$_graftty_codex_socket" ]; then
                    return 0
                  fi
                  if ! kill -0 "$_graftty_codex_app_server_pid" 2>/dev/null; then
                    return 1
                  fi
                  sleep 0.1
                  _graftty_wait_count=$((_graftty_wait_count + 1))
                done
                return 1
              }
              if ! _graftty_wait_for_codex_socket; then
                printf '%s\\n' "graftty: codex app-server failed to start; see $_graftty_codex_app_server_log" >&2
                kill "$_graftty_codex_app_server_pid" 2>/dev/null || true
                wait "$_graftty_codex_app_server_pid" 2>/dev/null || true
                rm -f "$_graftty_codex_socket"
                _graftty_preserve_codex_app_server_log=1
                cleanup_after_runtime
                exit 1
              fi
              \(shellCommandToken(grafttyCLIPath)) team codex-app-server register --socket "$_graftty_codex_socket" --real-binary "$real_binary" --app-server-pid "$_graftty_codex_app_server_pid" >/dev/null 2>&1 || true
              env CODEX_HOME=\(codexHomeLiteral) "$real_binary" --remote "unix://$_graftty_codex_socket" "$@"
              fi
            else
              "$real_binary" "$@"
            fi
            """
        }

        return """
        #!/bin/sh
        # GRAFTTY_AGENT_HOOK_WRAPPER version=\(version)
        # Hooks run: \(grafttyCLIPath) team hook \(runtime.rawValue)
        \(resolveBlock)

        \(registerBlock)

        \(cleanupBlock)

        \(runtimeBlock)
        runtime_status=$?
        cleanup_after_runtime
        exit "$runtime_status"
        """
    }

    /// @spec TEAM-IDLE-1.2
    /// Builds the inline `--settings` JSON payload that the Claude wrapper
    /// passes to `claude --settings '<json>'`. Lays the graftty hooks
    /// additively over the user's existing settings.
    private static func claudeInlineSettingsJSON(grafttyCLIPath: String) -> String {
        let cmd = grafttyCLIPath
        var hooks: [String: Any] = [:]
        for event in TeamHookEvent.allCases {
            if event == .stop {
                hooks[event.camelCaseKey] = [
                    [
                        "hooks": [
                            ["type": "command", "command": "\(cmd) team hook claude \(event.rawValue)"],
                            [
                                "type": "command",
                                "command": "\(cmd) team watch-inbox claude",
                                "async": true,
                                "asyncRewake": true,
                                "timeout": 86400,
                            ],
                        ],
                    ],
                ]
            } else {
                hooks[event.camelCaseKey] = hookEntries(command: "\(cmd) team hook claude \(event.rawValue)")
            }
        }
        let payload: [String: Any] = ["hooks": hooks]
        // Note: .sortedKeys produces alphabetical event order (PostToolUse, SessionStart, Stop).
        // JSON object key order has no semantic effect; sorting just keeps the wrapper output stable.
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func realBinaryResolutionShell(wrapperDirectory: String, realCommandName: String) -> String {
        """
        real_binary=""
        old_ifs="$IFS"
        IFS=":"
        for dir in $PATH; do
          if [ "$dir" = \(shellLiteral(wrapperDirectory)) ]; then
            continue
          fi
          if [ -x "$dir/\(realCommandName)" ]; then
            real_binary="$dir/\(realCommandName)"
            break
          fi
        done
        IFS="$old_ifs"

        if [ -z "$real_binary" ]; then
          printf '%s\\n' "graftty: unable to find real \(realCommandName) outside \(wrapperDirectory)" >&2
          exit 127
        fi
        """
    }

    private static func hookEntries(command: String) -> [[String: Any]] {
        [
            [
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                    ],
                ],
            ],
        ]
    }

    private func writeIfChanged(
        _ string: String,
        to url: URL,
        executable: Bool,
        written: inout [URL]
    ) throws {
        try writeIfChanged(Data(string.utf8), to: url, executable: executable, written: &written)
    }

    private func writeIfChanged(
        _ data: Data,
        to url: URL,
        executable: Bool,
        written: inout [URL]
    ) throws {
        let existing = try? Data(contentsOf: url)
        guard existing != data else {
            if executable {
                try makeExecutable(url)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        if executable {
            try makeExecutable(url)
        }
        written.append(url)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }

    private static func shellCommandToken(_ value: String) -> String {
        return shellLiteral(value)
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
