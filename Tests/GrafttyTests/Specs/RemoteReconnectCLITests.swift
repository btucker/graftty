import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit

@Suite("CLI remote reconnect")
struct RemoteReconnectCLITests {
    @Test("""
    @spec REMOTE-12.16: When `graftty remote reconnect-client <name-or-id>` runs on a host Mac, the application shall target one authenticated connected viewing Mac by exact name or device ID, obtain its reconnect acknowledgement before closing that control channel, and have the viewer reconnect only that host through its existing connection flow; unknown, ambiguous, disconnected, or unsupported clients shall produce an error without disconnecting another peer.
    """)
    func parsesReconnectClientCommand() throws {
        let command = try #require(
            GrafttyCLI.parseAsRoot(["remote", "reconnect-client", "Laptop"]) as? RemoteReconnectClient
        )
        #expect(command.target == "Laptop")
        let data = Data(#"{"type":"reconnect_remote_client","target":"Laptop"}"#.utf8)
        let request = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(request == .reconnectRemoteClient(target: "Laptop"))
        #expect(request.expectsResponse)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test("""
    @spec REMOTE-12.15: When `graftty remote reconnect <name-or-id>` identifies a saved Remote Mac by its exact name or device ID, the application shall request reconnect through its existing connection flow without requiring a current worktree, reject unknown or ambiguous targets and Macs needing pairing, and acknowledge the request without waiting for connection establishment.
    """)
    func parsesReconnectCommand() throws {
        let command = try #require(
            GrafttyCLI.parseAsRoot(["remote", "reconnect", "Studio Mac"]) as? RemoteReconnect
        )
        #expect(command.target == "Studio Mac")
        #expect(RemoteReconnect.helpMessage().contains("<name-or-id>"))
    }

    @Test(arguments: ["reconnect", "reconnect-client"], [[], [""], ["   "], ["Studio Mac", "extra"]])
    func rejectsInvalidTargets(subcommand: String, arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try GrafttyCLI.parseAsRoot(["remote", subcommand] + arguments)
        }
    }

    @Test func reconnectRequestRoundTripsWithoutWorktree() throws {
        let data = Data(#"{"type":"reconnect_remote_mac","target":"Studio Mac"}"#.utf8)
        let request = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(request.expectsResponse)
        let encoded = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(json == ["type": "reconnect_remote_mac", "target": "Studio Mac"])
    }
}
