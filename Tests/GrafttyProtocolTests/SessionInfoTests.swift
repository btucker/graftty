import Foundation
import Testing
@testable import GrafttyProtocol

@Suite
struct SessionInfoTests {

    @Test
    func encodesGoldenJSONShape() throws {
        let info = SessionInfo(
            name: "graftty-abcd1234",
            worktreePath: "/Users/me/projects/graftty/.worktrees/ios-app",
            repoDisplayName: "graftty",
            worktreeDisplayName: "ios-app"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(info)
        let expected = #"{"name":"graftty-abcd1234","repoDisplayName":"graftty","worktreeDisplayName":"ios-app","worktreePath":"\/Users\/me\/projects\/graftty\/.worktrees\/ios-app"}"#
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test
    func decodesGoldenJSONShape() throws {
        let raw = #"{"name":"graftty-abcd1234","repoDisplayName":"graftty","worktreeDisplayName":"ios-app","worktreePath":"/Users/me/projects/graftty/.worktrees/ios-app"}"#
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(raw.utf8))
        #expect(info.name == "graftty-abcd1234")
        #expect(info.repoDisplayName == "graftty")
        #expect(info.worktreeDisplayName == "ios-app")
        #expect(info.worktreePath == "/Users/me/projects/graftty/.worktrees/ios-app")
    }
}
