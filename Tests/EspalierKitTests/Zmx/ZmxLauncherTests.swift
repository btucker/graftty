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
}
