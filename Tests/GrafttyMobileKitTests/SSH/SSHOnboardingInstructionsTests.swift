#if canImport(UIKit)
import Testing
@testable import GrafttyMobileKit

@Suite
struct SSHOnboardingInstructionsTests {

    @Test
    func manualPasteInstructionsIncludeAuthorizedKeysAndPublicKey() {
        let key = "ecdsa-sha2-nistp256 AAAATEST graftty-mobile"
        let instructions = SSHOnboardingInstructions.manualPaste(publicKey: key)

        #expect(instructions.contains("authorized_keys"))
        #expect(instructions.contains(key))
        #expect(instructions.contains("chmod 600 ~/.ssh/authorized_keys"))
    }

    @Test
    func downloadedFileInstructionsReferenceExpectedFilename() {
        let instructions = SSHOnboardingInstructions.downloadedFile(filename: "graftty-mobile.pub")

        #expect(instructions.contains("cat ~/Downloads/graftty-mobile.pub >> ~/.ssh/authorized_keys"))
    }
}
#endif
