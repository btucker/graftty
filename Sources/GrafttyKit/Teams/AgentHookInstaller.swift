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

        // AGENT-6.11: the Claude provider plugin owns Claude's lifecycle
        // hooks, so Graftty no longer wraps `claude`. Remove a wrapper left
        // by an older Graftty; its inline hooks would otherwise duplicate the
        // plugin's.
        try removeManagedWrapperIfPresent(at: claudeWrapper)
        try writeIfChanged(
            AgentHookInstaller.codexWrapperScript(
                wrapperDirectory: binDirectory.path,
                grafttyCLIPath: grafttyCLIPath,
                codexHomeDirectory: codexHomeDirectory
            ),
            to: codexWrapper,
            executable: true,
            written: &written
        )
        #if os(macOS)
        try writeIfChanged(Self.openWrapperScript(grafttyCLIPath: grafttyCLIPath),
                           to: binDirectory.appendingPathComponent("open"),
                           executable: true, written: &written)
        try writeIfChanged("#!/bin/sh\nexec \(Self.shellCommandToken(grafttyCLIPath)) open \"$@\"\n",
                           to: binDirectory.appendingPathComponent("browser-offer"),
                           executable: true, written: &written)
        try writeIfChanged(Self.codexBrowserLauncherScript(rootDirectory: rootDirectory),
                           to: binDirectory.appendingPathComponent("codex-browser-tui"),
                           executable: true, written: &written)
        #endif

        try installZshInitShim(written: &written)
        try installBashInitShim(written: &written)

        return AgentHookInstallResult(writtenFiles: written)
    }

    private static func openWrapperScript(grafttyCLIPath: String) -> String {
        """
        #!/bin/sh
        # GRAFTTY_OPEN_WRAPPER version=\(version)
        if [ "$#" -eq 1 ] && [ -n "${GRAFTTY_SOCK:-}" ] && [ -n "${ZMX_SESSION:-}" ]; then
          case "$1" in
            [hH][tT][tT][pP]://*|[hH][tT][tT][pP][sS]://*) exec \(shellCommandToken(grafttyCLIPath)) open "$1" ;;
          esac
        fi
        exec '/usr/bin/open' "$@"
        """
    }

    private static func codexBrowserLauncherScript(rootDirectory: URL) -> String {
        let binary = rootDirectory.appendingPathComponent("codex-browser/codex").path
        let helper = binDirectory(rootDirectory: rootDirectory).appendingPathComponent("browser-offer").path
        return """
        #!/bin/sh
        native_binary=$1
        original_tui=$2
        shift 2
        browser_tui=\(shellCommandToken(binary))
        if [ -n "${GRAFTTY_SOCK:-}" ] && [ -n "${ZMX_SESSION:-}" ] && [ -x "$browser_tui" ]; then
          if native_version="$("$native_binary" --version 2>/dev/null)" &&
             browser_version="$("$browser_tui" --version 2>/dev/null)" &&
             [ -n "$native_version" ] && [ "$native_version" = "$browser_version" ]; then
            exec env CODEX_BROWSER_COMMAND=\(shellCommandToken(helper)) "$browser_tui" "$@"
          fi
          printf '%s\\n' 'graftty: browser-hook Codex version differs; using the installed Codex TUI' >&2
        fi
        exec "$original_tui" "$@"
        """
    }

    /// Remove only the file carrying Graftty's marker; an unexpected file in
    /// the managed bin is preserved rather than being treated as ours to
    /// delete.
    private func removeManagedWrapperIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8),
              contents.contains("# GRAFTTY_AGENT_HOOK_WRAPPER version=") else {
            return
        }
        try FileManager.default.removeItem(at: url)
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
                (basename == ".zshenv" ? Self.captureInitialCommandSnippet() + "\n" : "")
                    + Self.zshSourceShim(homeBasename: homeBasename)
                    + (basename == ".zshenv" ? "\n" + Self.zshInitialCommandSnippet() : ""),
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
        \(captureInitialCommandSnippet())

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

        \(runInitialCommandSnippet())
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
        \(ShellSleepActivity.zshHooks)

        """
    }

    /// Sources `~/.zlogin` (where RVM is conventionally loaded), then
    /// re-registers `precmdHookSnippet` so our precmd hook is positioned
    /// behind any precmd / chpwd hooks the user's `.zlogin` added. ZMX-6.8.
    static func zloginShim() -> String {
        zshSourceShim(homeBasename: ".zlogin") + "\n\n" + precmdHookSnippet() + "\n\n" + ShellSleepActivity.zshHooks
    }

    /// Capture before user init, so nested shells cannot inherit a launch.
    private static func captureInitialCommandSnippet() -> String {
        """
        if [ -n "${GRAFTTY_INITIAL_COMMAND-}" ]; then
            _graftty_initial_command="$GRAFTTY_INITIAL_COMMAND"
            _graftty_startup_receipt="${GRAFTTY_STARTUP_RECEIPT-}"
            unset GRAFTTY_INITIAL_COMMAND GRAFTTY_STARTUP_RECEIPT
        fi
        """
    }

    private static func initialCommandFunction() -> String {
        """
        _graftty_run_initial_command() {
            [ -n "${_graftty_initial_command-}" ] || return 0
            local _graftty_command="$_graftty_initial_command"
            unset _graftty_initial_command
            if [ -n "${GRAFTTY_AGENT_HOOKS_BIN-}" ]; then
                export PATH="$GRAFTTY_AGENT_HOOKS_BIN:$PATH"
            fi
            if [ -n "${_graftty_startup_receipt-}" ]; then
                (umask 077; : > "$_graftty_startup_receipt")
                unset _graftty_startup_receipt
            fi
            eval "$_graftty_command"
        }
        """
    }

    private static func runInitialCommandSnippet() -> String {
        """
        if [ -n "${_graftty_initial_command-}" ]; then
            \(initialCommandFunction())
            if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
                PROMPT_COMMAND+=(_graftty_run_initial_command)
            else
                PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\\n'}_graftty_run_initial_command"
            fi
        fi
        """
    }

    /// Install from .zshenv so a user's custom ZDOTDIR cannot bypass startup.
    /// zsh runs scheduled commands after all first-prompt environment hooks,
    /// including when the user disables line editing.
    private static func zshInitialCommandSnippet() -> String {
        """
        if [[ -o interactive && -n ${_graftty_initial_command-} ]]; then
            \(initialCommandFunction())
            _graftty_prepare_initial_command() {
                precmd_functions=(${precmd_functions:#_graftty_prepare_initial_command})
                zmodload zsh/sched
                sched +0 _graftty_run_initial_command
            }
            typeset -ga precmd_functions
            precmd_functions+=(_graftty_prepare_initial_command)
        fi
        """
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

    public static func codexWrapperScript(
        wrapperDirectory: String,
        grafttyCLIPath: String,
        codexHomeDirectory: String,
        codexSourceDirectory: String = CodexHomeMirror.defaultSourceDirectory().path
    ) throws -> String {
        try codexWrapperScript(
            wrapperDirectory: wrapperDirectory,
            grafttyCLIPath: grafttyCLIPath,
            codexHomeDirectory: codexHomeDirectory,
            codexSourceDirectory: codexSourceDirectory,
            codexLockCommandPath: "/usr/bin/lockf"
        )
    }

    /// The Codex launch wrapper. The Codex provider plugin owns lifecycle
    /// hooks and skills; the wrapper supplies the managed `CODEX_HOME`, the
    /// app-server transport Graftty delivers messages through, and presence
    /// registration. The script lives in `Teams/Resources/codex-wrapper.sh`;
    /// only the platform-specific TUI launch line is built here.
    static func codexWrapperScript(
        wrapperDirectory: String,
        grafttyCLIPath: String,
        codexHomeDirectory: String,
        codexSourceDirectory: String,
        codexLockCommandPath: String
    ) throws -> String {
        #if os(macOS)
        let launcher = shellCommandToken((wrapperDirectory as NSString).appendingPathComponent("codex-browser-tui"))
        let tuiCommand = """
        if [ -x \(launcher) ]; then
          env CODEX_HOME="$_graftty_codex_runtime_home" \(launcher) "$_graftty_codex_native_binary" "$real_binary" --enable hooks --remote "unix://$_graftty_codex_socket" "$@"
        else
          env CODEX_HOME="$_graftty_codex_runtime_home" "$real_binary" --enable hooks --remote "unix://$_graftty_codex_socket" "$@"
        fi
        """
        #else
        let tuiCommand = "env CODEX_HOME=\"$_graftty_codex_runtime_home\" \"$real_binary\" --enable hooks --remote \"unix://$_graftty_codex_socket\" \"$@\""
        #endif
        let codexLockPath = URL(fileURLWithPath: codexHomeDirectory)
            .appendingPathComponent(".graftty-mirror.lock")
            .path
        return try renderShellTemplate(codexWrapperTemplate(), values: [
            "VERSION": version,
            "GRAFTTY_CLI_PATH": grafttyCLIPath,
            "GRAFTTY_CLI": shellCommandToken(grafttyCLIPath),
            "WRAPPER_DIRECTORY": shellLiteral(wrapperDirectory),
            "WRAPPER_DIRECTORY_PATH": wrapperDirectory,
            "CODEX_HOME": shellLiteral(codexHomeDirectory),
            "CODEX_SOURCE": shellLiteral(codexSourceDirectory),
            "CODEX_LOCK": shellLiteral(codexLockPath),
            "LOCK_COMMAND": shellCommandToken(codexLockCommandPath),
            "TUI_COMMAND": tuiCommand,
        ])
    }

    enum ShellTemplateError: Error, Equatable {
        case missingTemplate(String)
        case unknownPlaceholder(String)
        case unterminatedPlaceholder(String)
        case unusedValues([String])
    }

    static func codexWrapperTemplate(in bundle: Bundle = GrafttyKitResourceBundle.bundle) throws -> String {
        guard let url = bundle.url(forResource: "codex-wrapper", withExtension: "sh") else {
            throw ShellTemplateError.missingTemplate("codex-wrapper.sh")
        }
        // The file ends with a newline for editors; the script never did.
        let template = try String(contentsOf: url, encoding: .utf8)
        return template.hasSuffix("\n") ? String(template.dropLast()) : template
    }

    /// Replaces each `{{NAME}}` with `values[NAME]` in one left-to-right
    /// pass, so a substituted path containing placeholder text stays literal.
    static func renderShellTemplate(_ template: String, values: [String: String]) throws -> String {
        var output = ""
        var used = Set<String>()
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                throw ShellTemplateError.unterminatedPlaceholder(
                    String(rest[open.upperBound...].prefix { $0 != "\n" })
                )
            }
            let name = String(rest[open.upperBound..<close.lowerBound])
            guard let value = values[name] else {
                throw ShellTemplateError.unknownPlaceholder(name)
            }
            output += value
            used.insert(name)
            rest = rest[close.upperBound...]
        }
        output += rest
        let unused = Set(values.keys).subtracting(used)
        guard unused.isEmpty else { throw ShellTemplateError.unusedValues(unused.sorted()) }
        return output
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
