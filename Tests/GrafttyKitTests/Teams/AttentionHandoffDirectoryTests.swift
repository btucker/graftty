import Foundation
import Testing
@testable import GrafttyKit

struct AttentionHandoffDirectoryTests {
    @Test("@spec AGENT-3.25: When an absolute GRAFTTY_ATTENTION_DIR is configured, the application shall use that directory for Attention handoff so isolated provider tests cannot publish into the user's notification queue.")
    func absoluteOverrideSelectsIsolatedDirectory() {
        #expect(AttentionFileHandoff.rootDirectory(environment: ["GRAFTTY_ATTENTION_DIR": "/private/tmp/isolated-attention"]).path
            == "/private/tmp/isolated-attention")
        #expect(AttentionFileHandoff.rootDirectory(environment: ["GRAFTTY_ATTENTION_DIR": "relative"])
            == AttentionFileHandoff.rootDirectory(environment: [:]))
        #expect(AttentionFileHandoff.rootDirectory(environment: ["GRAFTTY_ATTENTION_DIR": ""])
            == AttentionFileHandoff.rootDirectory(environment: [:]))
    }
}
