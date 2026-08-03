import Foundation
import Testing
@testable import GrafttyKit

@Suite("OffMainIO")
struct OffMainIOTests {
    @Test("@spec ATTN-2.19: When a control-socket request requires team inbox file I/O, the application shall execute that work off the main thread so the main actor stays free to serve concurrent control-socket requests and UI events.")
    @MainActor
    func bodyRunsOffMainThread() async throws {
        let throwingRanOnMain = try await OffMainIO.run { () throws -> Bool in
            Thread.isMainThread
        }
        #expect(!throwingRanOnMain)

        let ranOnMain = await OffMainIO.run { Thread.isMainThread }
        #expect(!ranOnMain)
    }

    @Test("Thrown errors propagate to the caller")
    @MainActor
    func errorsPropagate() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await OffMainIO.run { throw Boom() }
        }
    }
}
