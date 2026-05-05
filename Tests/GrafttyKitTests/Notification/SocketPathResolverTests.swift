import Testing
import Foundation
@testable import GrafttyKit

@Suite("SocketPathResolver")
struct SocketPathResolverTests {
    let customDir = URL(fileURLWithPath: "/var/tmp/graftty-test")

    @Test func setEnvValueWins() {
        let env = ["GRAFTTY_SOCK": "/tmp/custom.sock"]
        #expect(SocketPathResolver.resolve(environment: env, defaultDirectory: customDir)
                == "/tmp/custom.sock")
    }

    @Test func unsetEnvFallsBackToDefaultDirectory() {
        let env: [String: String] = [:]
        #expect(SocketPathResolver.resolve(environment: env, defaultDirectory: customDir)
                == "/var/tmp/graftty-test/graftty.sock")
    }

    @Test("""
    @spec ATTN-2.5: The CLI shall read the `GRAFTTY_SOCK` environment variable to locate the socket. If the variable is unset or set to an empty string, the CLI shall fall back to the default path `<Application Support>/Graftty/graftty.sock`. Treating empty as unset prevents a blank `GRAFTTY_SOCK=` line (e.g. from a sourced `.env` file) from redirecting the CLI to a nonexistent socket at the empty path.
    """)
    func emptyEnvIsTreatedAsUnset() {
        // The bug: sourcing `.env` with `GRAFTTY_SOCK=` leaves the
        // variable set to empty string. Pre-fix the CLI tried to
        // connect() to "" and surfaced as "Graftty is not running" —
        // wildly misleading. Treat empty as unset so the default
        // socket is used instead.
        let env = ["GRAFTTY_SOCK": ""]
        #expect(SocketPathResolver.resolve(environment: env, defaultDirectory: customDir)
                == "/var/tmp/graftty-test/graftty.sock")
    }

    @Test func whitespaceOnlyEnvIsNotTreatedAsEmpty() {
        // Conservative: "  " is a real (unusual) value. Don't second-
        // guess the user by trimming; only the literal empty string
        // counts as "unset-ish." Same-line comment on the
        // SocketPathResolver explains the rationale.
        let env = ["GRAFTTY_SOCK": "   "]
        #expect(SocketPathResolver.resolve(environment: env, defaultDirectory: customDir) == "   ")
    }
}
