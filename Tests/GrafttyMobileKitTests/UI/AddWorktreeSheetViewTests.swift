#if canImport(UIKit)
import Testing
@testable import GrafttyMobileKit

@Suite("AddWorktreeSheetView submit policy")
struct AddWorktreeSheetViewTests {
    @Test("""
@spec IOS-9.10: While the mobile Add Worktree sheet is valid and not submitting, pressing Return on a hardware keyboard shall submit Create; invalid or already-submitting forms shall ignore Return.
""")
    func returnSubmitPolicy() {
        #expect(AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: false))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: false, isSubmitting: false))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: true))
    }

    @Test("""
    @spec REMOTE-13.10: When GrafttyMobile creates a worktree while the \
    connected Mac exposes repositories from multiple Macs, the Add Worktree \
    sheet shall require an explicit target Mac selection before repository \
    selection and creation.
    """)
    func requiresExplicitTargetWhenMultipleMacsAreAvailable() {
        #expect(
            AddWorktreeSheetView.initialTargetID(
                preservedTargetID: nil,
                targetIDs: ["local", "remote"]
            ) == nil
        )
        #expect(
            AddWorktreeSheetView.initialTargetID(
                preservedTargetID: nil,
                targetIDs: ["local"]
            ) == "local"
        )
        #expect(
            AddWorktreeSheetView.initialTargetID(
                preservedTargetID: "remote",
                targetIDs: ["local", "remote"]
            ) == "remote"
        )
    }
}
#endif
