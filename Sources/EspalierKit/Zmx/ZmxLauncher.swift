import Foundation

/// Resolves the bundled `zmx` binary and translates Espalier pane
/// identifiers into zmx invocations.
///
/// # Lifetime
/// Created once at app startup with the resolved executable URL. The
/// public surface is small and synchronous; use `kill` from a background
/// queue if calling from the UI thread (see TerminalManager).
public final class ZmxLauncher: Sendable {

    /// URL to the `zmx` binary. May point to a path that does not exist;
    /// callers should consult `isAvailable` before assuming usability.
    public let executable: URL

    /// `ZMX_DIR` value to pass to every spawned `zmx` invocation. Scopes
    /// our daemons under app support so they don't collide with a
    /// user-private `zmx` running in Terminal.app.
    public let zmxDir: URL

    public init(executable: URL, zmxDir: URL) {
        self.executable = executable
        self.zmxDir = zmxDir
    }

    /// Convenience init that defaults `zmxDir` to
    /// `~/Library/Application Support/Espalier/zmx/`. Used by tests that
    /// don't care about the dir.
    public convenience init(executable: URL) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport
            .appendingPathComponent("Espalier", isDirectory: true)
            .appendingPathComponent("zmx", isDirectory: true)
        self.init(executable: executable, zmxDir: dir)
    }

    /// True when the binary at `executable` exists and is executable by
    /// the current process.
    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    /// Path to the per-session log file the zmx daemon writes to.
    /// `PWD-1.3` parses these for the `pty spawned session=… pid=<N>`
    /// line to recover the inner-shell PID.
    public func logFile(forSession sessionName: String) -> URL {
        zmxDir
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(sessionName).log")
    }

    /// Deterministic mapping from a pane UUID to a zmx session name.
    /// **Do not change this mapping** without a migration strategy —
    /// changing it orphans every existing user's daemons.
    ///
    /// Returns `"espalier-" + first-8-hex-of-uuid`. 32 bits of namespace
    /// uniqueness within a single user's `ZMX_DIR` is ample for the
    /// expected concurrent-pane count (dozens, not millions).
    public static func sessionName(for paneID: UUID) -> String {
        let hex = paneID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "espalier-\(hex.prefix(8))"
    }

    /// Instance overload for callers that already hold a launcher.
    public func sessionName(for paneID: UUID) -> String {
        ZmxLauncher.sessionName(for: paneID)
    }

    /// The single-string command to hand to `ghostty_surface_config_s.command`.
    /// Single-quotes the executable path so spaces or shell metacharacters
    /// in the install path don't break the spawn.
    ///
    /// Espalier itself does *not* use this for its panes — see
    /// `attachInitialInput` for the reason. This helper stays around so
    /// tests (and anyone invoking zmx via `sh -c`) have a straight-through
    /// command string.
    public func attachCommand(sessionName: String) -> String {
        // Defensively shell-quote the session name even though sessionName(for:)
        // emits only [a-z0-9-] today — future callers may pass user-supplied
        // names, and an unquoted shell-metachar in the command string would
        // be a code-injection footgun for libghostty's spawn path.
        "\(shellQuote(executable.path)) attach \(shellQuote(sessionName)) $SHELL"
    }

    /// Bytes Espalier writes into each pane's PTY via libghostty's
    /// `initial_input` as soon as the user's default shell starts up.
    ///
    /// Shape (no Ghostty integration):
    ///     `exec '<zmx>' attach '<session>' '<userShell>'\n`
    ///
    /// Shape (zsh with Ghostty integration available):
    ///     `GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR" ZDOTDIR='<res>/shell-integration/zsh'
    ///      exec '<zmx>' attach '<session>' '<userShell>'\n`
    ///
    /// The `exec` is load-bearing: it *replaces* the outer shell with
    /// `zmx attach`, so when the inner shell ends its session the whole
    /// PTY child dies. libghostty detects the child exit, fires
    /// `close_surface_cb`, and Espalier closes the pane.
    ///
    /// The ZDOTDIR re-injection is load-bearing when `userShell` is zsh:
    /// libghostty installs its shell integration by setting ZDOTDIR on
    /// the *outer* shell, but the integration's .zshenv restores ZDOTDIR
    /// to the user's original value before we ever run initial_input.
    /// Without the re-injection, the inner shell that zmx spawns after
    /// our `exec` sources only the user's normal rc files — no Ghostty
    /// integration, no chpwd-driven OSC 7, no OSC 133 prompt marks. That
    /// breaks PWD-follow, onShellReady, and the command-finished badge
    /// for every pane. Preserving the outgoing ZDOTDIR in
    /// GHOSTTY_ZSH_ZDOTDIR lets the integration's .zshenv restore the
    /// user's original dir on the other side so their .zshrc still runs.
    ///
    /// Non-zsh shells (bash, fish, sh) leave the prefix off — ZDOTDIR
    /// is a zsh-only mechanism, and those shells need different
    /// injection strategies we haven't implemented yet.
    ///
    /// Why not just set `config.command = attachCommand(...)` instead?
    /// libghostty auto-enables `wait-after-command = true` whenever
    /// `config.command` is non-empty (see upstream `embedded.zig`: "If
    /// this is set then the 'wait-after-command' option is also
    /// automatically set to true, since this is used for scripting.").
    /// With wait-after-command on, shell exit triggers a "Press any key
    /// to close" overlay instead of firing `close_surface_cb` — which
    /// means panes stop auto-closing on `exit`. Feeding the same command
    /// via `initial_input` into the default-shell spawn keeps
    /// wait-after-command at its default of false.
    public func attachInitialInput(
        sessionName: String,
        userShell: String,
        ghosttyResourcesDir: String? = nil
    ) -> String {
        let prefix = zshIntegrationPrefix(
            userShell: userShell,
            ghosttyResourcesDir: ghosttyResourcesDir
        )
        return prefix
            + "exec \(shellQuote(executable.path))"
            + " attach \(shellQuote(sessionName))"
            + " \(shellQuote(userShell))\n"
    }

    /// Argv form of the attach invocation, for callers that spawn `zmx attach`
    /// directly (not via a shell) — e.g. `WebSession` through `PtyProcess`.
    ///
    /// Resolves `$SHELL` at call time because there is no shell in the
    /// pipeline to expand it — `execve` passes argv verbatim, and zmx
    /// doesn't re-expand shell metacharacters in the command arg. Phase 1's
    /// `attachCommand` can use the literal `$SHELL` because its caller
    /// (the pane-spawn path) pipes the string through an outer shell.
    public func attachArgv(sessionName: String,
                           userShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash") -> [String] {
        [executable.path, "attach", sessionName, userShell]
    }

    /// Produce the `GHOSTTY_ZSH_ZDOTDIR=… ZDOTDIR=…` prefix for the
    /// `exec zmx attach …` line when the user's shell is zsh and a
    /// Ghostty resources directory is available. Returns an empty
    /// string (no prefix) otherwise. See `attachInitialInput` for
    /// why this is necessary.
    private func zshIntegrationPrefix(
        userShell: String,
        ghosttyResourcesDir: String?
    ) -> String {
        guard let root = ghosttyResourcesDir, !root.isEmpty else { return "" }
        guard (userShell as NSString).lastPathComponent == "zsh" else { return "" }
        let integrationDir = (root as NSString).appendingPathComponent("shell-integration/zsh")
        return "GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\""
            + " ZDOTDIR=\(shellQuote(integrationDir))"
            + " "
    }

    /// Env additions that should accompany every zmx invocation Espalier
    /// makes (both inline subprocess calls AND the libghostty-spawned
    /// `zmx attach` PTY child). Caller merges with any existing env.
    public func envAdditions() -> [String: String] {
        ["ZMX_DIR": zmxDir.path]
    }

    /// Produce a zmx-ready environment from `base`: applies `envAdditions`
    /// and strips `ZMX_SESSION`.
    ///
    /// Stripping ZMX_SESSION matters because zmx's `attach` prefers the
    /// env var over the positional session argument, so an inherited
    /// ZMX_SESSION (from a parent Espalier shell, or the developer's
    /// own terminal when running tests) silently overrides the session
    /// name we're trying to create. Symptom: `zmx attach X` emits
    /// `error: session "<parent's-session>" does not exist` and exits.
    public func subprocessEnv(from base: [String: String]) -> [String: String] {
        var env = base.merging(envAdditions()) { _, new in new }
        env.removeValue(forKey: "ZMX_SESSION")
        return env
    }

    /// `zmx kill --force <session>`. Synchronous; ignores nonzero exit
    /// (the most common nonzero is "session already gone" which is the
    /// successful outcome from our perspective). Logs are caller's
    /// responsibility — pipe stdout/stderr if needed.
    ///
    /// The caller is expected to dispatch this off the main thread.
    public func kill(sessionName: String) {
        guard isAvailable else { return }
        _ = try? ZmxRunner.capture(
            executable: executable,
            args: ["kill", "--force", sessionName],
            env: subprocessEnv(from: ProcessInfo.processInfo.environment)
        )
    }

    /// `zmx list --short`. Returns the set of session names known to
    /// the zmx daemon set in our `ZMX_DIR`. Throws on launch failure;
    /// returns an empty set on parse failure or unavailability.
    public func listSessions() throws -> Set<String> {
        guard isAvailable else { return [] }
        let output = try ZmxRunner.run(
            executable: executable,
            args: ["list", "--short"],
            env: subprocessEnv(from: ProcessInfo.processInfo.environment)
        )
        return Set(parseListOutput(output))
    }

    /// Parser exposed for unit testing. Splits on newlines, trims, drops
    /// empties. Each remaining line is treated as a session name.
    func parseListOutput(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Single-quote a string for use as a single shell token. Closes
    /// the quote, escapes any embedded single quotes, then reopens.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
