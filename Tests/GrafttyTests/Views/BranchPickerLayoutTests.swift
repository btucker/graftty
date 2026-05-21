import Testing
import SwiftUI
import AppKit
import GrafttyKit
@testable import Graftty

@Suite("BranchPicker layout")
@MainActor
struct BranchPickerLayoutTests {

    private func entries(count: Int = 1) -> [BranchPickerEntry] {
        (0..<count).map { i in
            BranchPickerEntry(
                name: "feat-\(i)",
                source: .local,
                lastCommitDate: Date(),
                mountedWorktreePath: nil,
                pr: nil
            )
        }
    }

    @Test("""
@spec GIT-5.20: While the user is in existing-branch mode, the BranchPicker's branch list shall reserve a fixed vertical height regardless of the parent view's proposed height, so the list never collapses to zero when nested inside a `Grid` cell whose row height is driven by sibling cells' intrinsic content.
""")
    func listReservesHeightUnderTightProposal() {
        let picker = BranchPicker(
            entries: entries(count: 3),
            selection: .constant(nil),
            onCommit: {}
        )
        // `sizeThatFits(in:)` proposes a constrained size down the view
        // tree the same way SwiftUI's layout passes a tight height when
        // the picker sits inside a `Grid` row whose other cells provide
        // only a baseline. With `.frame(maxHeight: 180)`, the List
        // collapses to whatever height the parent proposes (≈0); with
        // a fixed/min height it reserves its declared space.
        let host = NSHostingController(rootView: picker.frame(width: 360))
        let preferred = host.sizeThatFits(in: CGSize(width: 360, height: 40))
        #expect(
            preferred.height >= 180,
            "BranchPicker reported \(preferred.height)pt under a tight 40pt proposal — list collapsed instead of reserving its declared height"
        )
    }
}
