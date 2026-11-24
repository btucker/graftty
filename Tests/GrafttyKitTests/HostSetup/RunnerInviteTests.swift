import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

struct RunnerInviteTests {
    private static let identity = LinuxHostIdentity(deviceID: "runner-id", displayName: "Build Box",
        publicKey: Data(repeating: 7, count: 32).base64EncodedString(), port: 8801)

    private static func invite(secret: Data = Data(repeating: 9, count: 32)) -> RunnerInvite {
        RunnerInvite(identity: identity, endpoint: TailcatEndpoint(address: "fixture-address-\(UUID().uuidString)", port: 8801),
                     secret: secret, expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test("@spec REMOTE-33.7: When a runner invite is encoded and parsed, the application shall recover the runner identity, Tailcat endpoint, secret, and expiry.")
    func roundTrips() throws {
        let invite = Self.invite()
        let line = invite.encoded()
        #expect(line.hasPrefix(RunnerInvite.prefix))
        #expect(!line.contains { $0.isWhitespace })
        #expect(try RunnerInvite(parsing: "  " + line + "\n") == invite)
        #expect(RunnerInvite.looksLikeInvite(line))
        #expect(!String(describing: invite).contains(invite.endpoint.address))
        #expect(!String(describing: invite).contains(invite.secret.base64EncodedString()))
    }

    @Test(arguments: ["", "ssh user@host", "graftty-invite-1:", "graftty-invite-1:%%%%", "graftty-invite-2:abc"])
    func rejectsMalformedText(_ text: String) {
        #expect(throws: RunnerInviteError.malformed) { try RunnerInvite(parsing: text) }
    }

    @Test func rejectsTruncatedOrShortSecret() {
        let line = Self.invite().encoded()
        #expect(throws: RunnerInviteError.malformed) { try RunnerInvite(parsing: String(line.dropLast(8))) }
        #expect(throws: RunnerInviteError.malformed) { try RunnerInvite(parsing: Self.invite(secret: Data(repeating: 1, count: 31)).encoded()) }
    }

    @Test func enrollmentTokenRoundTripsThroughTheUsername() throws {
        let token = RunnerEnrollmentToken(secret: Data(repeating: 4, count: 32), deviceID: "mac-id", displayName: "My Mac")
        #expect(token.username.hasPrefix(RunnerEnrollmentToken.prefix))
        #expect(RunnerEnrollmentToken(username: token.username) == token)
        #expect(RunnerEnrollmentToken(username: "graftty") == nil)
    }

    @Test func inviteBookRedeemsEachSecretOnce() {
        let book = RunnerInviteBook()
        let issued = book.issue()
        #expect(issued.secret.count == RunnerInviteBook.secretLength)
        #expect(!book.redeem(Data(repeating: 0, count: 32)))
        #expect(book.redeem(issued.secret))
        #expect(!book.redeem(issued.secret))
    }

    @Test func inviteBookRefusesAnExpiredSecret() {
        let clock = Clock()
        let book = RunnerInviteBook(now: { clock.now })
        let issued = book.issue(lifetime: 3600)
        clock.now = clock.now.addingTimeInterval(3601)
        #expect(!book.redeem(issued.secret))
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }
}
