import Foundation
import Testing
@testable import GrafttyKit

@MainActor
@Suite("@spec ATTN-2.27: When the CLI sends `capabilities`, the application shall answer with the name of every control capability its dispatcher supports, and shall answer each older single-capability probe from that same set: `ok` when supported, an error otherwise.")
struct ControlCapabilityTests {
    @Test func listsThePlatformSetInDeclarationOrder() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities = [.worktreeBase, .paneAgent]
        #expect(await ControlRequestCore.handleRequest(.capabilities, platform: platform)
            == .capabilities(["pane_agent", "worktree_base"]))
        #expect(platform.platformRequests.isEmpty)
    }

    @Test func answersOlderProbesFromTheSameSet() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities = [.worktreeBase]
        for capability in ControlCapability.allCases {
            let expected: ResponseMessage = capability == .worktreeBase
                ? .ok : .error("operation is unavailable on this host")
            #expect(await ControlRequestCore.handleRequest(capability.legacyProbe, platform: platform) == expected)
        }
        #expect(platform.platformRequests.isEmpty)
    }
}
