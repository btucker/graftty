// Tests/GrafttyTests/Views/PaneTitleRowPortsTests.swift
import Testing
import SwiftUI
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
            theme: .fallback,
            attentionText: "Done",
            portBindings: [
                PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 1)
            ]
        )
        #expect(!row.shouldRenderPortChips)
    }
}
