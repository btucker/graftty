import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

struct TerminalBrowserRequestTests {
    @Test("@spec CHROME-2.15: When a terminal link is activated, the application shall retain its exact URL and user-request identity, present through the existing browser only in its active originating owned pane, and reject stale host, worktree, session or owner scope.")
    func retainsOriginAndRejectsReplacementScope() throws {
        let scope = TerminalBrowserRequest.Scope(hostID: UUID(), worktree: "/project", sessionName: "pane", ownerDeviceID: .init(value: "phone"))
        let url = try #require(URL(string: "https://example.com/a?state=A%2Bb&x=1#part"))
        let request = TerminalBrowserRequest(url: url, scope: scope)
        #expect(request.canPresent(in: scope, isActive: true, isOwner: true))
        #expect(!request.canPresent(in: scope, isActive: false, isOwner: true))
        #expect(!request.canPresent(in: scope, isActive: true, isOwner: false))
        for replacement in [
            TerminalBrowserRequest.Scope(hostID: UUID(), worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: "/other", sessionName: scope.sessionName, ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: "other", ownerDeviceID: scope.ownerDeviceID),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: .init(value: "other")),
            .init(hostID: scope.hostID, worktree: scope.worktree, sessionName: scope.sessionName, ownerDeviceID: nil),
        ] { #expect(!request.canPresent(in: replacement, isActive: true, isOwner: true)) }
        #expect(request.url.absoluteString == url.absoluteString)
        let launch = ChromeTabInitialLaunch(id: request.id, url: request.url.absoluteString)
        #expect(launch.action == .launchOffer(id: request.id, url: url.absoluteString))
        let reconnect = ChromeTabInitialLaunch(id: request.id, url: request.url.absoluteString)
        #expect(reconnect.action == launch.action, "Lost replies retain the host's launch receipt identity")
        #expect(launch.accept(.init(state: .init(tabs: [.init(id: "created", title: "Page", url: url.absoluteString)], selectedTabID: "created"))))
        #expect(launch.action == .select(tabID: "created"))
        #expect(TerminalBrowserRequest(url: url, scope: scope).id != request.id)
        let invalid = TerminalBrowserRequest(url: try #require(URL(string: "file:///tmp/file")), scope: scope)
        #expect(!invalid.canPresent(in: scope, isActive: true, isOwner: true))
    }
}
