#if canImport(UIKit)
import Testing
@testable import GrafttyMobileKit

@Suite("AddWorktreeSheetView submit policy")
struct AddWorktreeSheetViewTests {
    @Test("@spec IOS-9.10: While the mobile Add Worktree sheet is valid and not submitting, pressing Return on a hardware keyboard shall submit Create; invalid or already-submitting forms shall ignore Return.")
    func returnSubmitPolicy() {
        #expect(AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: false))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: false, isSubmitting: false))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: true))
    }
}
#endif
