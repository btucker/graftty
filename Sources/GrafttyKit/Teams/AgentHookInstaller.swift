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

    /// Sources the user's `~/.zlogin` (where RVM is conventionally loaded —
    /// sourcing RVM prepends gem/ruby paths to PATH, pushing our wrapper bin
    /// off position 1), then re-appends graftty's precmd hook so it runs
    /// *after* any precmd / chpwd hooks the user's `.zlogin` registered.
    /// ZMX-6.8.
    static func zloginShim() -> String {
        zshSourceShim(homeBasename: ".zlogin") + "\n\n" + precmdHookSnippet()
    }

    /// Inline shell block that (re-)installs the `_graftty_prepend_wrapper_path`
    /// precmd hook at the END of `precmd_functions` using a strip-then-append
    /// pattern. Embedded in both `zshrcShim` and `zloginShim`: the `.zshrc`
    /// registration handles cases where the user's `.zlogin` doesn't run
    /// (e.g. interactive non-login zsh); the `.zlogin` re-registration runs
    /// after the user's `.zlogin`, so any precmd / chpwd hooks the user's
    /// init registered (asdf, mise, nvm-on-cd, etc.) are positioned ahead
    /// of ours in `precmd_functions` and ours fires last each prompt.
    /// ZMX-6.8.
    private static func precmdHookSnippet() -> String {
        """
        # ZMX-6.8: keep graftty's wrapper bin at PATH position 1 across
        # every prompt by re-prepending in a precmd hook. The hook is
        # registered with strip-then-append so it appears exactly once in
        # precmd_functions; re-registering from .zlogin (after the user's
        # .zlogin has run) reorders us to the end of the chain, so we win
        # against any precmd / chpwd hooks user init registered (asdf, mise,
        # nvm-on-cd, etc.).
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
        let trapBlock = """
        cleanup() { \(shellCommandToken(grafttyCLIPath)) team unregister --runtime \(runtime.rawValue) 2>/dev/null || true; }
        trap cleanup EXIT
        """

        let runtimeBlock: String
        switch runtime {
        case .claude:
            let inlineJSON = claudeInlineSettingsJSON(grafttyCLIPath: grafttyCLIPath)
            let escapedJSON = shellLiteral(inlineJSON)
            runtimeBlock = """
            if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
              ( exec "$real_binary" --settings \(escapedJSON) "$@" )
            else
              ( exec "$real_binary" "$@" )
            fi
            """
        case .codex:
            let codexHomeLiteral = shellLiteral(codexHomeDirectory)
            runtimeBlock = """
            if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
              \(shellCommandToken(grafttyCLIPath)) internal sync-codex-home
              ( exec env CODEX_HOME=\(codexHomeLiteral) "$real_binary" "$@" )
            else
              ( exec "$real_binary" "$@" )
            fi
            """
        }

        return """
        #!/bin/sh
        # GRAFTTY_AGENT_HOOK_WRAPPER version=\(version)
        # Hooks run: \(grafttyCLIPath) team hook \(runtime.rawValue)
        \(resolveBlock)

        \(trapBlock)

        \(runtimeBlock)
        exit $?
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
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
              value.contains("'") ||
              value.contains("\"")
        else {
            return value
        }
        return shellLiteral(value)
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
