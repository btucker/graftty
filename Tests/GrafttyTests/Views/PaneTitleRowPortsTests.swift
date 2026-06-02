// Tests/GrafttyTests/Views/PaneTitleRowPortsTests.swift
import Testing
import SwiftUI
import AppKit
import GrafttyKit
@testable import Graftty

@Suite("PaneTitleRow port chip rendering and attention precedence")
struct PaneTitleRowPortsTests {
    @Test("@spec PORTS-3.1: While a pane has at least one `PortBinding`, the application shall render one `PortChip` per binding inline with the pane title.")
    func chipPerBinding() {
        let row = PaneTitleRow(
            title: "vite",
            isActiveWorktree: true,
            isFocusedPane: true,
            isBusy: false,
            theme: .fallback,
            attentionText: nil,
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
            attentionText: "Done",
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
            attentionText: nil,
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
    @Test("@spec LAYOUT-2.30: When a pane has an active attention capsule, the application shall render the capsule to the right of the pane title (not in place of it), truncating the title — so the row stays a single line rather than stacking the pill under the title.")
    func attentionPillRendersBesideTitleOnOneLine() {
        let containerWidth: CGFloat = 220
        func height(attention: String?) -> CGFloat {
            let row = PaneTitleRow(
                title: "Refactoring the parser module thoroughly",
                isActiveWorktree: true, isFocusedPane: true, isBusy: false,
                theme: .fallback, attentionText: attention, portBindings: [])
            return NSHostingController(rootView: row)
                .sizeThatFits(in: CGSize(width: containerWidth, height: 1000)).height
        }
        // A pill beside a (truncated) title occupies one line — within ~4pt
        // of the no-pill single-line height. Stacking the pill under the
        // title would roughly double it.
        #expect(abs(height(attention: "Claude needs input") - height(attention: nil)) < 6)
    }

    @MainActor
    @Test("@spec LAYOUT-2.22: A PaneTitleRow with a long title AND an attention capsule stays bounded by the row width (title truncates; pill keeps intrinsic size).")
    func longTitlePlusPillStaysBounded() {
        let containerWidth: CGFloat = 220
        let row = PaneTitleRow(
            title: String(repeating: "really-long-pane-title-segment-", count: 6),
            isActiveWorktree: true, isFocusedPane: true, isBusy: false,
            theme: .fallback, attentionText: "Claude needs input", portBindings: [])
        let preferred = NSHostingController(rootView: row)
            .sizeThatFits(in: CGSize(width: containerWidth, height: 1000))
        #expect(preferred.width <= containerWidth + 0.5)
    }
}
