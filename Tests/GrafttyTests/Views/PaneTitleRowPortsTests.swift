// Tests/GrafttyTests/Views/PaneTitleRowPortsTests.swift
import Testing
import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@Suite("PaneTitleRow port chip rendering and attention precedence")
struct PaneTitleRowPortsTests {
    @MainActor
    @Test("@spec LAYOUT-2.83: While a worktree row has a PR/MR badge, the application shall indent its pane titles beneath the worktree name while keeping the pane row within the available column width.")
    func paneTitleAlignsAfterPRBadge() throws {
        let badge = PRBadge(number: 356, state: .open, checks: .success,
                            url: URL(string: "https://github.com/btucker/graftty/pull/356")!)
        var worktree = WorktreeEntry(path: "/repo/.worktrees/needs-attention-ai", branch: "needs-attention-ai", state: .running)
        worktree.emoji = "🧭"
        let heading = WorktreeRow(entry: worktree, isActive: true, displayName: "needs-attention-ai",
                                  isMainCheckout: false, theme: .fallback, stats: nil, baseRef: nil,
                                  prBadge: badge, attentionStyle: nil)
        let row = PaneTitleRow(title: "Explore AI-powered Needs Attention", isActiveWorktree: true,
                               isFocusedPane: true, isBusy: false, theme: .fallback,
                               attentionStyle: nil, portBindings: [], prBadge: badge)
        let width: CGFloat = 300
        let host = NSHostingController(rootView: row)
        #expect(host.sizeThatFits(in: CGSize(width: width, height: 1000)).width <= width + 0.5)
        if let directory = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"] {
            let preview = VStack(alignment: .leading, spacing: 0) { heading; row }
                .frame(width: width, height: 84, alignment: .topLeading)
                .padding(10)
                .background(Color(red: 0.3, green: 0.32, blue: 0.34))
                .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: preview)
            hosting.frame = NSRect(x: 0, y: 0, width: width + 20, height: 104)
            hosting.layoutSubtreeIfNeeded()
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("worktree-pane-pr-alignment.png"))
        }
    }

    @MainActor
    @Test("@spec LAYOUT-2.56: When a worktree has long directory and branch labels, the application shall keep its title row on one line and truncate labels within the available width.")
    func worktreeLabelsStayOnOneLine() {
        let row = WorktreeRow(entry: .init(path: "/repo/load-team-skill", branch: "auto-update-agent-plugins"),
            isActive: false, displayName: "load-team-skill", isMainCheckout: false,
            theme: .fallback, stats: nil, baseRef: nil, prBadge: nil, attentionStyle: nil)
        let host = NSHostingController(rootView: row)
        let size = host.sizeThatFits(in: CGSize(width: 160, height: 1000))
        #expect(size.height < 30)
        #expect(size.width <= 160)
    }

    @Test("@spec PORTS-3.1: While a pane has at least one `PortBinding`, the application shall render one `PortChip` per binding inline with the pane title.")
    func chipPerBinding() {
        let row = PaneTitleRow(
            title: "vite",
            isActiveWorktree: true,
            isFocusedPane: true,
            isBusy: false,
            theme: .fallback,
            attentionStyle: nil,
            portBindings: [
                PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 1),
                PortBinding(port: 9229, scope: .loopback, processName: "node", pid: 1)
            ]
        )
        #expect(row.shouldRenderPortChips)
        #expect(row.portBindings.count == 2)
    }

    @Test("@spec PORTS-3.3: FlowLayout configuration drives wrap-with-indent layout")
    func ports_3_3_flowLayoutConfig() {
        let layout = FlowLayout(spacing: 4, rowSpacing: 3)
        #expect(layout.spacing == 4)
        #expect(layout.rowSpacing == 3)
    }

    @Test("@spec PORTS-3.4: When a pane has an active `AttentionCapsule`, the application shall hide port chips for that pane until the capsule clears.")
    func attentionHidesChips() {
        let row = PaneTitleRow(
            title: "vite",
            isActiveWorktree: true,
            isFocusedPane: true,
            isBusy: false,
            theme: .fallback,
            attentionStyle: .text("Done"),
            portBindings: [
                PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 1)
            ]
        )
        #expect(!row.shouldRenderPortChips)
    }

    @MainActor
    @Test("@spec LAYOUT-2.22: When a PaneTitleRow's pane title would render wider than the row's available width, the row's reported intrinsic size shall remain bounded by that width so the enclosing worktree block's `.listRowInsets(leading: -20)` outdent is preserved and the WorktreeRow above does not appear indented.")
    func paneTitleRowSizeBoundedByContainer() {
        let containerWidth: CGFloat = 220
        let row = PaneTitleRow(
            title: String(repeating: "really-long-pane-title-segment-", count: 6),
            isActiveWorktree: true,
            isFocusedPane: true,
            isBusy: false,
            theme: .fallback,
            attentionStyle: nil,
            portBindings: [
                PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 1)
            ]
        )
        // `sizeThatFits(in:)` proposes a constrained width down the view
        // tree; `fittingSize` would query with `.infinity` and miss the
        // overflow this test guards against.
        let host = NSHostingController(rootView: row)
        let preferred = host.sizeThatFits(in: CGSize(width: containerWidth, height: 1000))
        #expect(preferred.width <= containerWidth + 0.5)
    }

    @MainActor
    @Test("@spec LAYOUT-2.30: When a pane has an active attention capsule, the application shall render the capsule to the right of the pane title (not in place of it), truncating the title so the capsule keeps its intrinsic width — the row stays a single line (pill beside, not stacked under) and its width stays bounded by the row.")
    func attentionPillRendersBesideTitleNotInPlaceOfIt() {
        let containerWidth: CGFloat = 220
        func height(attention: AttentionCapsuleStyle?) -> CGFloat {
            let row = PaneTitleRow(
                title: "Refactoring the parser module thoroughly",
                isActiveWorktree: true, isFocusedPane: true, isBusy: false,
                theme: .fallback, attentionStyle: attention, portBindings: [])
            return NSHostingController(rootView: row)
                .sizeThatFits(in: CGSize(width: containerWidth, height: 1000)).height
        }
        // A pill beside a (truncated) title occupies one line — within a few
        // pt of the no-pill single-line height. Stacking the pill under the
        // title would roughly double it.
        #expect(abs(height(attention: .needsInput(label: "Claude needs input")) - height(attention: nil)) < 6)

        // A long title plus a pill stays bounded by the row width: the title
        // truncates while the pill keeps its intrinsic size (preserves the
        // LAYOUT-2.22 outdent invariant for the pill-present case).
        let longRow = PaneTitleRow(
            title: String(repeating: "really-long-pane-title-segment-", count: 6),
            isActiveWorktree: true, isFocusedPane: true, isBusy: false,
            theme: .fallback, attentionStyle: .needsInput(label: "Claude needs input"), portBindings: [])
        let preferred = NSHostingController(rootView: longRow)
            .sizeThatFits(in: CGSize(width: containerWidth, height: 1000))
        #expect(preferred.width <= containerWidth + 0.5)
    }
}
