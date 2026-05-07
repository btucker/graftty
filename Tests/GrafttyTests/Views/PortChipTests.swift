// Tests/GrafttyTests/Views/PortChipTests.swift
import Testing
import Foundation
import GrafttyKit
@testable import Graftty

@Suite("PortChip click + tooltip behavior")
struct PortChipTests {
    @Test("@spec PORTS-3.5: When the user clicks a `PortChip`, the application shall open `http://localhost:<port>/` via `NSWorkspace.shared.open`.")
    func clickURL() {
        let binding = PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 1)
        #expect(PortChip.url(for: binding) == URL(string: "http://localhost:3000/"))
    }

    @Test("@spec PORTS-3.6: When a `PortChip` is hovered, the application shall display a tooltip reading `Open http://localhost:<port>/`.")
    func tooltipText() {
        let binding = PortBinding(port: 5000, scope: .lan, processName: "flask", pid: 1)
        #expect(PortChip.tooltip(for: binding) == "Open http://localhost:5000/")
    }

    @Test("@spec PORTS-3.2: PortChip icon name is `personalhotspot` for .loopback, `globe` for .lan")
    func iconNameByScope() {
        let loop = PortBinding(port: 3000, scope: .loopback, processName: "n", pid: 1)
        let lan  = PortBinding(port: 5000, scope: .lan,      processName: "n", pid: 1)
        #expect(PortChip.iconNameForTesting(for: loop) == "personalhotspot")
        #expect(PortChip.iconNameForTesting(for: lan)  == "globe")
    }
}
