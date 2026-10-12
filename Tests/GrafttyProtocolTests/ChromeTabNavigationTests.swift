import Foundation
import GrafttyProtocol
import Testing

struct ChromeTabNavigationTests {
    @Test("@spec CHROME-3.4: When browser navigation crosses the Chrome channel, the application shall encode typed back, forward, and reload actions with their selected-tab identity, reject invalid tab identities, and decode state from hosts without navigation availability.")
    func preservesTypedNavigationAndLegacyState() throws {
        for name in ["back", "forward", "reload"] {
            for tab in ["selected", "", String(repeating: "x", count: 129)] {
                let bytes = try JSONSerialization.data(withJSONObject: [name: ["tabID": tab]])
                let action = try JSONDecoder().decode(ChromeTabAction.self, from: bytes)
                #expect(action.tabID == tab)
                #expect(action.isValid == (tab == "selected"))
                let request = ChromeTabRequest(target: "pane", action: action)
                #expect(try JSONDecoder().decode(ChromeTabRequest.self, from: JSONEncoder().encode(request)) == request)
            }
        }
        let legacy = try JSONDecoder().decode(ChromeTabState.self, from: Data("{\"tabs\":[],\"selectedTabID\":\"selected\"}".utf8))
        #expect(legacy.selectedTabID == "selected")
        #expect(legacy.canGoBack == nil)
        #expect(legacy.canGoForward == nil)
        let current = ChromeTabState(selectedTabID: "selected", canGoBack: false, canGoForward: true)
        #expect(try JSONDecoder().decode(ChromeTabState.self, from: JSONEncoder().encode(current)) == current)
    }
}
