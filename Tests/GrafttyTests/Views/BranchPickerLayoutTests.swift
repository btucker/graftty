import Testing
import SwiftUI
import AppKit
import GrafttyKit
@testable import Graftty

@Suite("BranchPicker layout")
@MainActor
struct BranchPickerLayoutTests {

    private func entries(count: Int) -> [BranchPickerEntry] {
        (0..<count).map { i in
            BranchPickerEntry(
                name: "feat-\(i)",
                source: .local,
                lastCommitDate: Date(timeIntervalSince1970: 0),
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
        // Propose a 40pt height to mirror the tight proposal a `Grid`
        // cell passes when sibling rows dominate intrinsic content.
        let host = NSHostingController(rootView: picker)
        let preferred = host.sizeThatFits(in: CGSize(width: 360, height: 40))
        #expect(
            preferred.height >= 180,
            "BranchPicker reported \(preferred.height)pt under a tight 40pt proposal — list collapsed instead of reserving its declared height"
        )
    }
}
