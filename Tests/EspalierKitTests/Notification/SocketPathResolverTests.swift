import Testing
import Foundation
@testable import EspalierKit

@Suite("SocketPathResolver")
struct SocketPathResolverTests {
    let customDir = URL(fileURLWithPath: "/var/tmp/espalier-test")

    @Test func setEnvValueWins() {
        let env = ["ESPALIER_SOCK": "/tmp/custom.sock"]
        #expect(SocketPathResolver.resolve(environment: env, defaultDirectory: customDir)
                == "/tmp/custom.sock")
    }

    @Test func unsetEnvFallsBackToDefaultDirectory() {
        let env: [String: String] = [:]
        #expect(SocketPathResolver.resolve(environment: env, defaultDirectory: customDir)
                == "/var/tmp/espalier-test/espalier.sock")
    }

    @Test func emptyEnvIsTreatedAsUnset() {
        // The bug: sourcing `.env` with `ESPALIER_SOCK=` leaves the
        // variable set to empty string. Pre-fix the CLI tried to
        // connect() to "" and surfaced as "Espalier is not running" —
        // wildly misleading. Treat empty as unset so the default
        // socket is used instead.
        let env = ["ESPALIER_SOCK": ""]
        #expect(SocketPathResolver.resolve(environment: env, defaultDirectory: customDir)
                == "/var/tmp/espalier-test/espalier.sock")
    }

    @Test func whitespaceOnlyEnvIsNotTreatedAsEmpty() {
        // Conservative: "  " is a real (unusual) value. Don't second-
        // guess the user by trimming; only the literal empty string
        // counts as "unset-ish." Same-line comment on the
        // SocketPathResolver explains the rationale.
        let env = ["ESPALIER_SOCK": "   "]
        #expect(SocketPathResolver.resolve(environment: env, defaultDirectory: customDir) == "   ")
    }
}
