import Foundation
import GrafttyProtocol
import Testing

struct PRInfoTests {
    @Test func headCommitSurvivesCodingAndLegacyDataStillDecodes() throws {
        let info = PRInfo(number: 5, title: "Change", url: URL(string: "https://example.com/pr/5")!,
                          state: .open, checks: .failure, headSHA: "head", fetchedAt: Date())
        let encoded = try JSONEncoder().encode(info)
        #expect(try JSONDecoder().decode(PRInfo.self, from: encoded) == info)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "headSHA")
        let decoded = try JSONDecoder().decode(PRInfo.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.headSHA == nil)
        #expect(decoded.checks == .failure)
        #expect(decoded != info)
    }
}
