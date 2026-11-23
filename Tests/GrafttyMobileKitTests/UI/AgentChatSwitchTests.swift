import Foundation
import Testing
@testable import GrafttyMobileKit

struct AgentChatSwitchTests {
    @Test func theIPhoneRemembersItsViewForEachTab() throws {
        let suite = "agent-chat-switch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UUID()
        func shows(_ session: String, on host: UUID = host, path: String = "/repo/wt") -> Bool {
            MobileChatViewChoice.showsChat(hostID: host, worktreePath: path, sessionName: session, defaults: defaults)
        }

        #expect(shows("s1") == false)
        MobileChatViewChoice.setShowsChat(true, hostID: host, worktreePath: "/repo/wt", sessionName: "s1", defaults: defaults)
        #expect(shows("s1"))
        #expect(shows("s2") == false)
        #expect(shows("s1", path: "/repo/other") == false)
        #expect(shows("s1", on: UUID()) == false)

        MobileChatViewChoice.setShowsChat(false, hostID: host, worktreePath: "/repo/wt", sessionName: "s1", defaults: defaults)
        #expect(shows("s1") == false)
        #expect(defaults.object(forKey: MobileChatViewChoice.key(hostID: host, worktreePath: "/repo/wt", sessionName: "s1")) == nil)
    }
}
