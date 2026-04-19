import Testing
import Foundation
@testable import EspalierKit

@Suite("ZmxLauncher — pure logic")
struct ZmxLauncherUnitTests {

    // MARK: sessionName(for:)
    //
    // The session name is the join key between Espalier and the zmx
    // daemon. Once a user upgrades and starts a daemon under a given
    // name, changing this function would orphan that daemon — they'd
    // get a fresh shell instead of their reattached one.

    @Test func sessionNameIsDeterministic() throws {
        let id = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let name = launcher.sessionName(for: id)
        #expect(name == "espalier-deadbeef")
    }

    @Test func sessionNameUsesFirst8HexCharsOfUUID() throws {
        // First 8 hex chars of any UUID are the leading 4 bytes.
        let id = UUID(uuidString: "01234567-89AB-CDEF-FEDC-BA9876543210")!
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        #expect(launcher.sessionName(for: id) == "espalier-01234567")
    }

    @Test func sessionNameDiffersForDifferentUUIDs() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let a = launcher.sessionName(for: UUID())
        let b = launcher.sessionName(for: UUID())
        #expect(a != b)
    }

    @Test func sessionNameAlwaysHasEspalierPrefix() throws {
        // Locks in the "espalier-" prefix as part of the contract — a
        // future maintainer who renames the prefix would have to update
        // this test, making the breakage visible.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        for _ in 0..<10 {
            let name = launcher.sessionName(for: UUID())
            #expect(name.hasPrefix("espalier-"))
        }
    }

    @Test func sessionNameIsExactlySeventeenCharacters() throws {
        // "espalier-" (9) + 8 hex chars = 17. Locks in the length so a
        // change to "first 4 hex" or "full uuid" gets caught.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        for _ in 0..<10 {
            let name = launcher.sessionName(for: UUID())
            #expect(name.count == 17)
        }
    }

    @Test func sessionNameIsAlwaysLowercase() throws {
        // The .lowercased() call is one of the easier mutations to drop
        // accidentally; a UUID that has uppercase hex letters in its
        // first 8 chars (which most do) would surface as uppercase
        // without it. Tests both an explicit upper-case UUID and a
        // sample of fresh ones.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let upperUUID = UUID(uuidString: "AABBCCDD-EEFF-0011-2233-445566778899")!
        #expect(launcher.sessionName(for: upperUUID) == "espalier-aabbccdd")
        for _ in 0..<5 {
            let name = launcher.sessionName(for: UUID())
            #expect(name == name.lowercased())
        }
    }

    // MARK: attachCommand(sessionName:)
    //
    // libghostty's `command` field is a single string (shell parses it).
    // We single-quote the executable path defensively in case the user
    // installed Espalier somewhere with spaces in the path.

    @Test func attachCommandIncludesQuotedExecutableAndSession() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/Applications/Espalier.app/Contents/Helpers/zmx")
        )
        let cmd = launcher.attachCommand(sessionName: "espalier-deadbeef")
        #expect(cmd == "'/Applications/Espalier.app/Contents/Helpers/zmx' attach 'espalier-deadbeef' $SHELL")
    }

    @Test func attachCommandEscapesSingleQuotesInExecutablePath() throws {
        // Path with a single quote — single-quote escaping pattern is
        // ' → '\''  (close, escape, reopen). Defensive even if rare.
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/tmp/it's/zmx")
        )
        let cmd = launcher.attachCommand(sessionName: "espalier-cafe1234")
        #expect(cmd == "'/tmp/it'\\''s/zmx' attach 'espalier-cafe1234' $SHELL")
    }

    @Test func attachCommandQuotesSessionNameDefensively() throws {
        // sessionName(for:) emits safe strings, but attachCommand accepts
        // arbitrary input — verify shell metacharacters in the session
        // name are quoted, not interpreted.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))
        let cmd = launcher.attachCommand(sessionName: "my session; rm -rf /")
        #expect(cmd == "'/usr/bin/zmx' attach 'my session; rm -rf /' $SHELL")
    }

    // MARK: attachInitialInput(sessionName:userShell:)
    //
    // This is the string Espalier writes into the PTY as soon as the user's
    // default shell starts (via libghostty's `initial_input` config). It
    // uses `exec` so the shell is *replaced* by `zmx attach`, which means
    // when the inner shell exits the PTY child dies with it — libghostty
    // sees a normal child exit and fires `close_surface_cb`. This is the
    // path that keeps Espalier out of libghostty's "wait-after-command"
    // mode, which Ghostty auto-enables whenever `config.command` is set.

    @Test func attachInitialInputUsesExecWithTrailingNewline() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/Applications/Espalier.app/Contents/Helpers/zmx")
        )
        let input = launcher.attachInitialInput(
            sessionName: "espalier-deadbeef",
            userShell: "/bin/zsh"
        )
        #expect(
            input ==
            "exec '/Applications/Espalier.app/Contents/Helpers/zmx'"
            + " attach 'espalier-deadbeef' '/bin/zsh'\n"
        )
    }

    @Test func attachInitialInputEscapesSingleQuotes() throws {
        // Same ' → '\''  escape as attachCommand, applied to every field
        // that gets substituted in: executable path, session name, shell.
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/tmp/it's/zmx")
        )
        let input = launcher.attachInitialInput(
            sessionName: "espalier-cafe1234",
            userShell: "/opt/al'berto/sh"
        )
        #expect(
            input ==
            "exec '/tmp/it'\\''s/zmx' attach 'espalier-cafe1234'"
            + " '/opt/al'\\''berto/sh'\n"
        )
    }

    @Test func attachInitialInputAlwaysEndsWithLineTerminator() throws {
        // Without the trailing \n the shell won't execute the line; the
        // bytes just sit in the kernel's PTY buffer until the user hits
        // Enter. Guard against someone "simplifying" the trailing \n away.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))
        let input = launcher.attachInitialInput(
            sessionName: "espalier-x",
            userShell: "/bin/sh"
        )
        #expect(input.hasSuffix("\n"))
    }

    @Test func attachInitialInputStartsWithExec() throws {
        // `exec` is the load-bearing keyword: without it the shell forks
        // zmx as a child, and when zmx exits the user drops back to their
        // shell prompt rather than closing the pane. `exec` replaces the
        // shell process, so when zmx exits the PTY child is gone.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))
        let input = launcher.attachInitialInput(
            sessionName: "espalier-x",
            userShell: "/bin/sh"
        )
        #expect(input.hasPrefix("exec "))
    }

    // MARK: Ghostty zsh shell-integration pass-through
    //
    // Ghostty activates its zsh integration by setting ZDOTDIR to
    // `<resources>/shell-integration/zsh` when libghostty spawns the PTY
    // child. That integration dir's .zshenv immediately restores ZDOTDIR
    // to the user's original value and then sources the Ghostty hooks.
    // By the time our `exec zmx attach …` initial_input runs, ZDOTDIR is
    // back to the user's normal value — so the *inner* shell spawned by
    // zmx's daemon would never re-source the integration, and chpwd's
    // OSC 7 (and OSC 133 prompt marks, etc.) would stop firing across
    // the zmx hop. PWD-follow, default-command, and command-finished
    // badges all depend on that integration staying active in the inner
    // shell.
    //
    // Fix: when the user's shell is zsh and a Ghostty resources root is
    // supplied, prefix the exec line with a ZDOTDIR re-injection that
    // points back at Ghostty's integration dir — and save the outgoing
    // ZDOTDIR into GHOSTTY_ZSH_ZDOTDIR so the integration's .zshenv
    // can restore the user's original on the other side.

    @Test func attachInitialInputReInjectsZshIntegrationZDOTDIRWhenAvailable() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/Applications/Espalier.app/Contents/Helpers/zmx")
        )
        let input = launcher.attachInitialInput(
            sessionName: "espalier-deadbeef",
            userShell: "/bin/zsh",
            ghosttyResourcesDir: "/Applications/Ghostty.app/Contents/Resources/ghostty"
        )
        #expect(
            input ==
            "GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\""
            + " ZDOTDIR='/Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration/zsh'"
            + " exec '/Applications/Espalier.app/Contents/Helpers/zmx'"
            + " attach 'espalier-deadbeef' '/bin/zsh'\n"
        )
    }

    @Test func attachInitialInputWorksForAnyZshInstallPath() throws {
        // Homebrew zsh at /opt/homebrew/bin/zsh, MacPorts at
        // /usr/local/bin/zsh, user-built at ~/bin/zsh, etc. — all should
        // get the re-injection because basename is still "zsh".
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))
        for shell in ["/opt/homebrew/bin/zsh", "/usr/local/bin/zsh", "/home/user/bin/zsh"] {
            let input = launcher.attachInitialInput(
                sessionName: "espalier-x",
                userShell: shell,
                ghosttyResourcesDir: "/ghostty"
            )
            #expect(
                input.hasPrefix("GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\" ZDOTDIR='/ghostty/shell-integration/zsh' exec "),
                "expected ZDOTDIR prefix for \(shell); got: \(input)"
            )
        }
    }

    @Test func attachInitialInputOmitsZshPrefixWhenShellIsNotZsh() throws {
        // bash doesn't honor ZDOTDIR; fish has its own config model.
        // Leaving the prefix off is the safe default — integration pass-
        // through for non-zsh shells is a separate follow-up.
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/usr/bin/zmx")
        )
        for shell in ["/bin/bash", "/usr/local/bin/fish", "/bin/sh"] {
            let input = launcher.attachInitialInput(
                sessionName: "espalier-x",
                userShell: shell,
                ghosttyResourcesDir: "/Applications/Ghostty.app/Contents/Resources/ghostty"
            )
            #expect(
                input.hasPrefix("exec "),
                "\(shell) should not get the zsh ZDOTDIR prefix; got: \(input)"
            )
        }
    }

    @Test func attachInitialInputOmitsZshPrefixWhenNoGhosttyResourcesProvided() throws {
        // Backwards-compatible: when callers don't pass a resources dir,
        // behavior matches the original exec-only form. This is the
        // Ghostty-not-installed path.
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/usr/bin/zmx")
        )
        let input = launcher.attachInitialInput(
            sessionName: "espalier-x",
            userShell: "/bin/zsh",
            ghosttyResourcesDir: nil
        )
        #expect(input.hasPrefix("exec "))
    }

    @Test func attachInitialInputShellQuotesGhosttyResourcesDir() throws {
        // Same ' → '\'' defense as every other substituted field. Path
        // with a space is the common real-world case (users with
        // Ghostty in `/Applications/My Apps/Ghostty.app`).
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/usr/bin/zmx")
        )
        let input = launcher.attachInitialInput(
            sessionName: "espalier-x",
            userShell: "/bin/zsh",
            ghosttyResourcesDir: "/Applications/My Apps/Ghostty.app/Contents/Resources/ghostty"
        )
        #expect(
            input.contains(
                " ZDOTDIR='/Applications/My Apps/Ghostty.app/Contents/Resources/ghostty/shell-integration/zsh' "
            )
        )
    }

    // MARK: parseListOutput
    //
    // `zmx list --short` emits one session name per line. (The non-short
    // form emits tab-separated key=value pairs; we don't parse that.)

    @Test func parsesEmptyListOutput() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        #expect(launcher.parseListOutput("") == [])
        #expect(launcher.parseListOutput("\n") == [])
    }

    @Test func parsesSingleSession() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        #expect(launcher.parseListOutput("espalier-deadbeef\n") == ["espalier-deadbeef"])
    }

    @Test func parsesManySessions() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let output = """
        espalier-aaaa1111
        espalier-bbbb2222
        espalier-cccc3333
        """
        #expect(
            launcher.parseListOutput(output) ==
            ["espalier-aaaa1111", "espalier-bbbb2222", "espalier-cccc3333"]
        )
    }

    @Test func parseListSkipsBlankLines() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let output = "espalier-aaaa1111\n\n\nespalier-bbbb2222\n"
        #expect(
            launcher.parseListOutput(output) ==
            ["espalier-aaaa1111", "espalier-bbbb2222"]
        )
    }

    // MARK: isAvailable

    @Test func isAvailableFalseWhenExecutableMissing() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/nonexistent/path/zmx")
        )
        #expect(launcher.isAvailable == false)
    }

    @Test func isAvailableTrueForExistingExecutable() throws {
        // /bin/sh is universally executable
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/bin/sh"))
        #expect(launcher.isAvailable == true)
    }

    // MARK: subprocessEnv(from:)
    //
    // zmx's `attach <name>` silently prefers $ZMX_SESSION over the
    // positional name arg. An inherited ZMX_SESSION (from the shell that
    // launched Espalier or `swift test`) therefore hijacks every attach.
    // subprocessEnv must strip it — these tests lock that invariant.

    @Test func subprocessEnvStripsInheritedZmxSession() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp/some-dir")
        )
        let base = ["ZMX_SESSION": "espalier-leaked", "PATH": "/usr/bin"]
        let env = launcher.subprocessEnv(from: base)
        #expect(env["ZMX_SESSION"] == nil)
        #expect(env["PATH"] == "/usr/bin")  // unrelated keys preserved
    }

    @Test func subprocessEnvAppliesZmxDir() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp/zmx-xyz")
        )
        let env = launcher.subprocessEnv(from: [:])
        #expect(env["ZMX_DIR"] == "/tmp/zmx-xyz")
    }

    @Test func subprocessEnvOverridesInheritedZmxDir() throws {
        // If the parent already had a ZMX_DIR, our launcher's dir wins.
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp/ours")
        )
        let env = launcher.subprocessEnv(from: ["ZMX_DIR": "/somewhere/else"])
        #expect(env["ZMX_DIR"] == "/tmp/ours")
    }

    // MARK: sanitizeProcessEnvironment — surface-spawn env leak fix (ZMX-7.4)
    //
    // User-reported regression: creating a new worktree via the UI
    // attached the new pane's Claude session to an OLDER worktree's
    // still-running zmx session. Root cause: Espalier.app was launched
    // from a terminal that already lived inside a zmx session, so the
    // app process inherited `ZMX_SESSION=<old-name>`. libghostty
    // spawns each new pane's shell with Espalier.app's env + the small
    // overlay `ghostty_surface_config_s.env_vars` carries. That env
    // overlay doesn't strip ZMX_SESSION, so the spawned shell's
    // `exec zmx attach 'espalier-<new-hex>' <shell>` line hit zmx with
    // `$ZMX_SESSION = <old-name>`, and zmx prefers the env var over
    // the positional arg — attaching to the OLD session.
    //
    // `subprocessEnv` already solves this for inline subprocess spawns
    // (CLI uses `ProcessInfo.processInfo.environment`), but surface
    // spawns use libghostty's env overlay which Espalier can't feed
    // through `subprocessEnv` before the spawn. Cleanest fix:
    // `unsetenv("ZMX_SESSION")` in `EspalierApp.init()` so NOTHING
    // downstream sees it, regardless of spawn mechanism.
    //
    // `sanitizeProcessEnvironment()` calls `unsetenv` for the names
    // in `leakyEnvKeysToStrip`. Test surface: verify the key list
    // contains `ZMX_SESSION` and that the impure sweep actually
    // unsets a set value.

    @Test func leakyEnvKeysIncludesZmxSession() {
        #expect(ZmxLauncher.leakyEnvKeysToStripAtAppLaunch.contains("ZMX_SESSION"))
    }

    @Test func leakyEnvKeysIncludesGitDir() {
        // `GIT_DIR` inherited from the launch shell would redirect every
        // Espalier git invocation (`GitRunner.run(at: repoPath)`) to the
        // shell's .git dir instead of the target repo's. CLIRunner sets
        // `process.currentDirectoryURL` correctly but git's env-var-wins
        // rule trumps CWD. Same leak class as ZMX_SESSION.
        #expect(ZmxLauncher.leakyEnvKeysToStripAtAppLaunch.contains("GIT_DIR"))
    }

    @Test func leakyEnvKeysIncludesGitWorkTree() {
        // Companion hijack to GIT_DIR. Less commonly set, but together
        // they let a tainted launch shell redirect every worktree
        // discovery / stats fetch.
        #expect(ZmxLauncher.leakyEnvKeysToStripAtAppLaunch.contains("GIT_WORK_TREE"))
    }

    @Test func sanitizeProcessEnvironmentUnsetsZmxSession() {
        setenv("ZMX_SESSION", "espalier-leaked-from-parent", 1)
        defer { unsetenv("ZMX_SESSION") }
        ZmxLauncher.sanitizeProcessEnvironment()
        #expect(getenv("ZMX_SESSION") == nil)
    }

    @Test func sanitizeProcessEnvironmentUnsetsGitDir() {
        setenv("GIT_DIR", "/some/other/repo/.git", 1)
        defer { unsetenv("GIT_DIR") }
        ZmxLauncher.sanitizeProcessEnvironment()
        #expect(getenv("GIT_DIR") == nil)
    }

    // MARK: isSessionMissing
    //
    // The contract: when zmx itself can't answer (binary missing,
    // subprocess throws), return "not missing" so spurious session-loss
    // recoveries don't fire. The true-when-absent case is covered by
    // the integration test (real zmx daemon spawn-then-kill).

    @Test func isSessionMissingFalseWhenBinaryUnavailable() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/nonexistent/path/zmx")
        )
        #expect(launcher.isSessionMissing("espalier-aaaa1111") == false)
    }

    @Test func isSessionMissingFalseWhenListSessionsThrows() throws {
        // /bin/sh is executable so isAvailable is true, but listSessions
        // throws because it isn't zmx — locks the throw → false bias.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/bin/sh"))
        #expect(launcher.isSessionMissing("anything") == false)
    }
}
