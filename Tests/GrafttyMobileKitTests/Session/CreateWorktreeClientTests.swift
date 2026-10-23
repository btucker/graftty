#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
struct CreateWorktreeClientTests {

    @Test
    func userMessageSurfacesServerErrorVerbatim() {
        let err = CreateWorktreeClient.CreateError.serverInternal("fatal: worktree already exists")
        #expect(err.userMessage == "fatal: worktree already exists")
    }

    @Test
    func userMessageHasStableFallbackForTransportErrors() {
        #expect(CreateWorktreeClient.CreateError.transport.userMessage == "Couldn't reach the server.")
    }
}
#endif
