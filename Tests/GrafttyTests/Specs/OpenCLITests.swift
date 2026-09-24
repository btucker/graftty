import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit
import GrafttyProtocol

struct OpenCLITests {
    @Test("@spec IOS-12.3: When the user runs graftty open with a file path, the CLI shall send the caller's pane session with the file in its tracked worktree and report request failures.")
    func parsesFileArgumentAndEncodesRequest() throws {
        let command = try Open.parse(["./report with spaces.html"])
        #expect(command.target == "./report with spaces.html")
        #expect(throws: (any Error).self) { try Open.parse([]) }
        let message = Open.request(path: "/project", target: "/tmp/report.html", environment: ["ZMX_SESSION": "graftty-pane"])
        #expect(message == .offerResource(path: "/project", target: "/tmp/report.html", paneSessionName: "graftty-pane"))
        #expect(message.expectsResponse)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(message)) == message)
        let oldMessage = Data(#"{"type":"open_resource","path":"/project","target":"/tmp/report.html"}"#.utf8)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: oldMessage) ==
            .offerResource(path: "/project", target: "/tmp/report.html"))
    }

    @Test("@spec IOS-12.8: When graftty open runs in a pane led by GrafttyMobile, the host shall offer its resource to mobile; when Mac or another client leads or the pane is unknown, the host shall open it with macOS.")
    func routesByPaneOwnership() throws {
        let store = SessionDisplayOwnershipStore()
        let session = "graftty-pane"
        let client = DisplayClientID("phone")
        let grid = try DisplayGrid(cols: 80, rows: 24)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: true, ownershipStore: store) == .mac)
        _ = store.attachClient(sessionName: session, clientID: client, kind: .ios, role: .interactive, visible: true, grid: grid)
        _ = store.claimOwner(sessionName: session, clientID: client, kind: .ios, grid: grid)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: true, ownershipStore: store) == .mobile)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: false, ownershipStore: store) == .mac)
        #expect(OpenResourceRouting.destination(
            paneSessionName: nil, belongsToWorktree: false, ownershipStore: store) == .mac)
        _ = store.releaseOwner(sessionName: session, clientID: client)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: true, ownershipStore: store) == .mac)
        let mac = DisplayClientID("mac")
        _ = store.attachClient(sessionName: session, clientID: mac, kind: .mac, role: .interactive, visible: true, grid: grid)
        _ = store.claimOwner(sessionName: session, clientID: mac, kind: .mac, grid: grid)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: true, ownershipStore: store) == .mac)
    }
}
