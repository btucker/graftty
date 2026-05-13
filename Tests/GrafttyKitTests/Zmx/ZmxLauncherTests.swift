import Testing
import Foundation
@testable import GrafttyKit

@Suite("ZmxLauncher — pure logic")
struct ZmxLauncherUnitTests {

    // MARK: sessionName(for:)
    //
    // The session name is the join key between Graftty and the zmx
    // daemon. Once a user upgrades and starts a daemon under a given
    // name, changing this function would orphan that daemon — they'd
    // get a fresh shell instead of their reattached one.

    @Test("""
    @spec ZMX-2.2: The session-naming function shall be deterministic and shall not change across releases without an explicit migration step, since changing it orphans every existing user's daemons.
    """)
    func sessionNameIsDeterministic() throws {
        let id = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let name = launcher.sessionName(for: id)
        #expect(name == "graftty-deadbeef")
    }

    @Test("""
    @spec ZMX-2.1: The application shall derive the zmx session name for each pane as the literal string `"graftty-"` followed by the first 8 lowercase hex characters (i.e., the leading 4 bytes, yielding 32 bits of namespace uniqueness) of the pane's UUID with dashes stripped.
    """)
    func sessionNameUsesFirst8HexCharsOfUUID() throws {
        // First 8 hex chars of any UUID are the leading 4 bytes.
        let id = UUID(uuidString: "01234567-89AB-CDEF-FEDC-BA9876543210")!
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        #expect(launcher.sessionName(for: id) == "graftty-01234567")
    }

    @Test func sessionNameUsesPaneSessionID() {
        let sessionID = PaneSessionID(id: UUID(uuidString: "01234567-89AB-CDEF-FEDC-BA9876543210")!)
        #expect(ZmxLauncher.sessionName(for: sessionID) == "graftty-01234567")
    }

    @Test func sessionNameDiffersForDifferentUUIDs() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let a = launcher.sessionName(for: UUID())
        let b = launcher.sessionName(for: UUID())
        #expect(a != b)
    }

    @Test func sessionNameAlwaysHasGrafttyPrefix() throws {
        // Locks in the "graftty-" prefix as part of the contract — a
        // future maintainer who renames the prefix would have to update
        // this test, making the breakage visible.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        for _ in 0..<10 {
            let name = launcher.sessionName(for: UUID())
            #expect(name.hasPrefix("graftty-"))
        }
    }

    @Test func sessionNameIsExactlySixteenCharacters() throws {
        // "graftty-" (8) + 8 hex chars = 16. Locks in the length so a
        // change to "first 4 hex" or "full uuid" gets caught.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        for _ in 0..<10 {
            let name = launcher.sessionName(for: UUID())
            #expect(name.count == 16)
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
        #expect(launcher.sessionName(for: upperUUID) == "graftty-aabbccdd")
        for _ in 0..<5 {
            let name = launcher.sessionName(for: UUID())
            #expect(name == name.lowercased())
        }
    }

    // MARK: attachCommand(sessionName:)
    //
    // libghostty's `command` field is a single string (shell parses it).
    // We single-quote the executable path defensively in case the user
    // installed Graftty somewhere with spaces in the path.

    @Test func attachCommandIncludesQuotedExecutableAndSession() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/Applications/Graftty.app/Contents/Helpers/zmx")
        )
        let cmd = launcher.attachCommand(sessionName: "graftty-deadbeef")
        #expect(cmd == "'/Applications/Graftty.app/Contents/Helpers/zmx' attach 'graftty-deadbeef' $SHELL")
    }

    @Test func attachCommandEscapesSingleQuotesInExecutablePath() throws {
        // Path with a single quote — single-quote escaping pattern is
        // ' → '\''  (close, escape, reopen). Defensive even if rare.
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/tmp/it's/zmx")
        )
        let cmd = launcher.attachCommand(sessionName: "graftty-cafe1234")
        #expect(cmd == "'/tmp/it'\\''s/zmx' attach 'graftty-cafe1234' $SHELL")
    }

    @Test func attachCommandQuotesSessionNameDefensively() throws {
        // sessionName(for:) emits safe strings, but attachCommand accepts
        // arbitrary input — verify shell metacharacters in the session
        // name are quoted, not interpreted.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))
        let cmd = launcher.attachCommand(sessionName: "my session; rm -rf /")
        #expect(cmd == "'/usr/bin/zmx' attach 'my session; rm -rf /' $SHELL")
    }

    @Test func attachArgvWithoutUserShellOmitsPositionalShell() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))

        let argv = launcher.attachArgv(sessionName: "graftty-deadbeef")

        #expect(argv == ["/usr/bin/zmx", "attach", "graftty-deadbeef"])
    }

    @Test func attachArgvWithExplicitUserShellAppendsPositional() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/usr/bin/zmx"))

        let argv = launcher.attachArgv(sessionName: "graftty-cafe1234", userShell: "/bin/zsh")

        #expect(argv == ["/usr/bin/zmx", "attach", "graftty-cafe1234", "/bin/zsh"])
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
        #expect(launcher.parseListOutput("graftty-deadbeef\n") == ["graftty-deadbeef"])
    }

    @Test func parsesManySessions() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let output = """
        graftty-aaaa1111
        graftty-bbbb2222
        graftty-cccc3333
        """
        #expect(
            launcher.parseListOutput(output) ==
            ["graftty-aaaa1111", "graftty-bbbb2222", "graftty-cccc3333"]
        )
    }

    @Test func parseListSkipsBlankLines() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let output = "graftty-aaaa1111\n\n\ngraftty-bbbb2222\n"
        #expect(
            launcher.parseListOutput(output) ==
            ["graftty-aaaa1111", "graftty-bbbb2222"]
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
    // launched Graftty or `swift test`) therefore hijacks every attach.
    // subprocessEnv must strip it — these tests lock that invariant.

    @Test func subprocessEnvStripsInheritedZmxSession() throws {
        let launcher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp/some-dir")
        )
        let base = ["ZMX_SESSION": "graftty-leaked", "PATH": "/usr/bin"]
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

    @Test("""
    @spec ZMX-3.1: The application shall pass `ZMX_DIR=~/Library/Application Support/Graftty/zmx/` in the environment of every spawned `zmx` invocation, so Graftty-owned daemons live in a private socket directory distinct from any user-personal `zmx` usage.
    """)
    func defaultZmxDirIsPassedToSpawnedZmxInvocations() throws {
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/dev/null"))
        let expected = AppState.defaultDirectory.appendingPathComponent("zmx", isDirectory: true).path
        #expect(launcher.envAdditions()["ZMX_DIR"] == expected)
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
    // still-running zmx session. Root cause: Graftty.app was launched
    // from a terminal that already lived inside a zmx session, so the
    // app process inherited `ZMX_SESSION=<old-name>`. zmx prefers the
    // env var over the positional arg, so any attach path that inherits
    // it can target the OLD session instead of the pane's session.
    //
    // Native panes now use `ZmxSpawnConfiguration` for host-managed
    // attach env and `subprocessEnv` still protects inline zmx commands.
    // The global app-start sweep remains a defense for any future helper
    // subprocess that reads `ProcessInfo.processInfo.environment`.
    //
    // `sanitizeProcessEnvironment()` calls `unsetenv` for the names
    // in `leakyEnvKeysToStrip`. Test surface: verify the key list
    // contains `ZMX_SESSION` and that the impure sweep actually
    // unsets a set value.

    @Test("""
    @spec ZMX-7.4: At application launch, before any terminal surface is spawned, the application shall `unsetenv(...)` inherited process environment variables whose values would hijack downstream spawns into the parent shell's scope. The list shall include at minimum: `ZMX_SESSION`, `GIT_DIR`, and `GIT_WORK_TREE`.
    """)
    func leakyEnvKeysIncludesZmxSession() {
        #expect(ZmxLauncher.leakyEnvKeysToStripAtAppLaunch.contains("ZMX_SESSION"))
    }

    @Test func leakyEnvKeysIncludesGitDir() {
        // `GIT_DIR` inherited from the launch shell would redirect every
        // Graftty git invocation (`GitRunner.run(at: repoPath)`) to the
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
        setenv("ZMX_SESSION", "graftty-leaked-from-parent", 1)
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
        #expect(launcher.isSessionMissing("graftty-aaaa1111") == false)
    }

    @Test("""
    @spec ZMX-7.2: If `zmx list` fails for any reason at the cold-start query site (per `ZMX-7.1`), the application shall treat the result as "session not missing" and take no recovery action — preferring a missed recovery over a spurious rehydration clear.
    """)
    func isSessionMissingFalseWhenListSessionsThrows() throws {
        // /bin/sh is executable so isAvailable is true, but listSessions
        // throws because it isn't zmx — locks the throw → false bias.
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/bin/sh"))
        #expect(launcher.isSessionMissing("anything") == false)
    }
}
