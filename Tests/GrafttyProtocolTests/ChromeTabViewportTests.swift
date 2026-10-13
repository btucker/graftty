import Foundation
import GrafttyProtocol
import Testing

struct ChromeTabViewportTests {
    @Test("@spec CHROME-3.5: When a viewer requests a typed selected-tab viewport, the application shall accept widths from 320 through 1024 and heights from 240 through 1600 within 1500000 pixels and reject other dimensions or invalid tab identities.")
    func validatesViewportCommandBounds() throws {
        for (tab, width, height, valid) in [
            ("selected", 320, 240, true), ("selected", 375, 812, true),
            ("selected", 1024, 768, true), ("selected", 320, 1600, true),
            ("selected", 1024, 1464, true), ("selected", 1024, 1465, false),
            ("selected", 319, 240, false), ("selected", 1025, 768, false),
            ("selected", 375, 239, false), ("selected", 375, 1601, false),
            ("selected", Int.max, Int.max, false), ("selected", 0, -1, false),
            ("", 375, 812, false), (String(repeating: "t", count: 129), 375, 812, false)
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["viewport": ["tabID": tab, "width": width, "height": height]])
            let action = try JSONDecoder().decode(ChromeTabAction.self, from: data)
            #expect(action.tabID == tab)
            #expect(action.isValid == valid)
            #expect(try JSONDecoder().decode(ChromeTabAction.self, from: JSONEncoder().encode(action)) == action)
        }
    }

    @Test("@spec CHROME-3.6: When viewport metadata crosses the Chrome channel, the application shall preserve each frame's CSS width, height, and viewport identity and decode legacy frames and state without that metadata.")
    func preservesFrameAndStateGeometryAndLegacyDecoding() throws {
        let data = Data("{\"tabs\":[],\"selectedTabID\":\"selected\",\"width\":375,\"height\":812,\"viewportID\":7,\"frame\":{\"tabID\":\"selected\",\"jpeg\":\"/9g=\",\"sequence\":42,\"width\":375,\"height\":812,\"viewportID\":7}}".utf8)
        let state = try JSONDecoder().decode(ChromeTabState.self, from: data)
        let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        let frame = try #require(roundTrip["frame"] as? [String: Any])
        for object in [roundTrip, frame] {
            #expect(object["width"] as? Int == 375)
            #expect(object["height"] as? Int == 812)
            #expect(object["viewportID"] as? Int == 7)
        }
        let legacy = try JSONDecoder().decode(ChromeTabState.self, from: Data("{\"tabs\":[],\"selectedTabID\":\"selected\",\"frame\":{\"tabID\":\"selected\",\"jpeg\":\"/9g=\",\"sequence\":1}}".utf8))
        #expect(legacy.frame?.jpeg == Data([0xff, 0xd8]))
        #expect(legacy.frame?.sequence == 1)
    }

    @Test("@spec CHROME-3.7: When a host tab URL exceeds its metadata budget, the application shall preserve an optional truncation flag across the Chrome channel and decode legacy tabs without that flag.")
    func preservesURLTruncationMetadata() throws {
        let data = Data("{\"id\":\"tab\",\"title\":\"Title\",\"url\":\"https://example.com\",\"urlTruncated\":true}".utf8)
        let tab = try JSONDecoder().decode(ChromeTab.self, from: data)
        let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as! [String: Any]
        #expect(roundTrip["urlTruncated"] as? Bool == true)
        #expect(try JSONDecoder().decode(ChromeTab.self, from: Data("{\"id\":\"tab\",\"title\":\"Title\",\"url\":\"https://example.com\"}".utf8)).url == "https://example.com")
    }

    @Test("@spec CHROME-3.8: When a Chrome response contains a selected-tab URL bounded to 8192 bytes, 31 other URLs bounded to 2048 bytes, and a maximum-size JPEG, the application shall encode JSON-escaped metadata within the one-megabyte response limit.")
    func keepsMaximumResponseWithinWireLimit() throws {
        let tabs = (0..<32).map { index in
            ChromeTab(id: "tab\(index)", title: String(repeating: "\"\\", count: 128), url: "https://example.com/" + String(repeating: "\"\\", count: ((index == 0 ? 8192 : 2048) - 20) / 2), urlTruncated: index != 0)
        }
        let frame = ChromeTabFrame(tabID: "tab0", jpeg: Data(repeating: 0xff, count: ChromeTabFrame.maximumJPEGBytes), sequence: 1, width: 375, height: 812, viewportID: 1)
        let response = ChromeTabResponse(state: .init(tabs: tabs, selectedTabID: "tab0", frame: frame, width: 375, height: 812, viewportID: 1))
        #expect(try response.encoded().count <= ChromeTabRequest.maximumResponseBytes)
    }
}
