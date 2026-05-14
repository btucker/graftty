import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyKit

@Suite("BranchPickerViewModel.autoSelect")
struct BranchPickerAutoSelectTests {

    private func entry(_ name: String, mounted: String? = nil) -> BranchPickerEntry {
        BranchPickerEntry(
            name: name,
            source: .local,
            lastCommitDate: Date(),
            mountedWorktreePath: mounted,
            pr: nil
        )
    }

    @Test("@spec GIT-5.17: When the filter text changes and the currently selected branch no longer matches the filter (or no branch is selected), the application shall auto-select the first non-mounted branch in the filtered list. When the filter is cleared, the prior selection shall be preserved if it still exists.")
    func autoSelectsFirstNonMountedWhenSelectionMissing() {
        let a = entry("alpha")
        let b = entry("beta")
        // No prior selection → picks first.
        #expect(BranchPickerViewModel.autoSelect(currentSelection: nil, in: [a, b])?.name == "alpha")
        // Prior selection no longer in list → picks first.
        let gone = entry("gone")
        #expect(BranchPickerViewModel.autoSelect(currentSelection: gone, in: [a, b])?.name == "alpha")
    }

    @Test func preservesSelectionStillInList() {
        let a = entry("alpha")
        let b = entry("beta")
        #expect(BranchPickerViewModel.autoSelect(currentSelection: b, in: [a, b])?.name == "beta")
    }

    @Test func skipsMountedEntriesWhenChoosingFirst() {
        let mounted = entry("alpha", mounted: "/r/.worktrees/alpha")
        let b = entry("beta")
        #expect(BranchPickerViewModel.autoSelect(currentSelection: nil, in: [mounted, b])?.name == "beta")
    }

    @Test func returnsNilWhenAllEntriesMountedAndNoPrior() {
        let mounted = entry("alpha", mounted: "/r/.worktrees/alpha")
        #expect(BranchPickerViewModel.autoSelect(currentSelection: nil, in: [mounted]) == nil)
    }

    @Test func returnsNilWhenEmpty() {
        #expect(BranchPickerViewModel.autoSelect(currentSelection: nil, in: []) == nil)
    }
}
