// Tests/GrafttyTests/Views/PortChipTests.swift
import Testing
import Foundation
import GrafttyKit
@testable import Graftty

@Suite("@spec PORTS-3.5 / PORTS-3.6: PortChip click + tooltip behavior")
struct PortChipTests {
    @Test("@spec PORTS-3.5: PortChip computes the URL it will hand to NSWorkspace.shared.open")
    func clickURL() {
        let binding = PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 1)
        #expect(PortChip.url(for: binding) == URL(string: "http://localhost:3000/"))
    }

    @Test("@spec PORTS-3.6: PortChip tooltip text reads 'Open http://localhost:<port>/'")
    func tooltipText() {
        let binding = PortBinding(port: 5000, scope: .lan, processName: "flask", pid: 1)
        #expect(PortChip.tooltip(for: binding) == "Open http://localhost:5000/")
    }
}
