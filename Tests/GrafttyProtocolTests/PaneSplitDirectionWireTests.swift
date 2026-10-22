import Foundation
import Testing
@testable import GrafttyProtocol

/// `Fixtures/pane-split-direction-v1.json` was encoded before the split
/// direction enums were unified (#484): pane-control split/resize requests in
/// every direction, which keep the legacy right/down tokens (`REMOTE-7.7`),
/// and keybind directions, which code as their raw values.
@Suite("Pane split direction wire fixture")
struct PaneSplitDirectionWireTests {
    struct Fixture: Codable, Equatable {
        var paneControl: [PaneControlRequest]
        var ghostty: [GhosttySplitDirection]
    }

    static let expected = Fixture(
        paneControl: [PaneSplitDirection.right, .down, .left, .up].flatMap { direction -> [PaneControlRequest] in
            [.split(target: "s", direction: direction),
             .resize(target: "s", direction: direction, amount: 3, viewportExtent: 900)]
        },
        ghostty: [.left, .right, .up, .down])

    private func fixture() throws -> Data {
        try WireFixture.data("pane-split-direction-v1")
    }

    @Test
    func releasedEncoderOutputDecodesToTheSameDirections() throws {
        #expect(try JSONDecoder().decode(Fixture.self, from: fixture()) == Self.expected)
    }

    @Test
    func currentEncoderProducesTheReleasedJSON() throws {
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.expected)) as? NSDictionary
        let released = try JSONSerialization.jsonObject(with: fixture()) as? NSDictionary
        #expect(current != nil)
        #expect(current == released)
    }

    @Test
    func keybindAndPaneControlShareOneDirectionType() {
        #expect(ObjectIdentifier(GhosttySplitDirection.self) == ObjectIdentifier(PaneControlRequest.SplitDirection.self))
    }
}
