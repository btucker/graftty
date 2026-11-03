import Foundation
import AppKit
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@MainActor
struct WorktreeRowLabelTests {
    @Test("@spec LAYOUT-2.56: When a worktree has long directory and branch labels, the application shall keep its title row on one line and truncate labels within the available width.")
    func worktreeLabelsStayOnOneLine() {
        let row = WorktreeRow(entry: .init(path: "/repo/load-team-skill", branch: "auto-update-agent-plugins"),
            isActive: false, displayName: "load-team-skill", isMainCheckout: false,
            theme: .fallback, stats: nil, baseRef: nil, prBadge: nil)
        let host = NSHostingController(rootView: row)
        let size = host.sizeThatFits(in: CGSize(width: 160, height: 1000))
        #expect(size.height < 30)
        #expect(size.width <= 160)
    }

    @Test("@spec LAYOUT-2.204: When a row shows its host, the application shall place the host name after the worktree name on one line within the available width.")
    func hostLabelStaysOnOneLine() {
        let row = WorktreeRow(entry: .init(path: "/repo/load-team-skill", branch: "main"),
            isActive: false, displayName: "load-team-skill", isMainCheckout: false,
            theme: .fallback, stats: nil, baseRef: nil, prBadge: nil, hostLabel: "build-box")
        let host = NSHostingController(rootView: row)
        let size = host.sizeThatFits(in: CGSize(width: 160, height: 1000))
        #expect(size.height < 30)
        #expect(size.width <= 160)
    }
}

@Suite("@spec REMOTE-13.46: When the user changes host in Add Worktree, the application shall keep the typed name and clear a selected branch that doesn't exist on the new host.")
struct AddWorktreeHostSwitchTests {
    private func entry(_ name: String) -> BranchPickerEntry {
        BranchPickerEntry(name: name, source: .local, lastCommitDate: Date(timeIntervalSince1970: 1), mountedWorktreePath: nil, pr: nil)
    }
    @Test func switchingKeepsNameAndBranchThatExists() {
        let form = AddWorktreeFormController(initialWorktreeName: "typed")
        form.carry(existingBranch: "feature", entries: [entry("feature")])
        #expect(form.worktreeName == "typed")
        #expect(form.branchMode == .existing)
        #expect(form.existingSelection?.name == "feature")
    }
    @Test func switchingClearsMissingBranch() {
        let form = AddWorktreeFormController(initialWorktreeName: "typed")
        form.carry(existingBranch: "feature", entries: [entry("other")])
        #expect(form.worktreeName == "typed")
        #expect(form.branchMode == .newBranch)
        #expect(form.existingSelection == nil)
    }
}
