import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec WEB-1.20: If a LocalAPI transport fails before its channel is initialized, then the application shall complete the request with a recoverable socket error and release all request resources.")
struct LocalAPIBootstrapFailureTests {
    @Test func overlongUnixPathReportsUnreachableWithoutLeakingPromise() async {
        let api = TailscaleLocalAPI(socketPath: "/tmp/" + String(repeating: "x", count: 200))
        await #expect(throws: TailscaleLocalAPI.Error.socketUnreachable) {
            _ = try await api.status()
        }
    }
}
