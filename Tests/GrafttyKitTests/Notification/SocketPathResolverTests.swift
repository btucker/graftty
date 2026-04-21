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

    @Test func emptyEnvIsTreatedAsUnset() {
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
