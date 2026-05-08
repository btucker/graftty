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
        #expect(PortChip.iconName(for: loop) == "personalhotspot")
        #expect(PortChip.iconName(for: lan)  == "globe")
    }

    @Test("@spec PORTS-3.7: When a `PortChip` renders a port number, the application shall display the digits without locale grouping separators (e.g., `:8080`, not `:8,080`).")
    func labelHasNoGroupingSeparator() {
        let four = PortBinding(port: 8080, scope: .loopback, processName: "n", pid: 1)
        let five = PortBinding(port: 53000, scope: .loopback, processName: "n", pid: 1)
        #expect(PortChip.label(for: four) == ":8080")
        #expect(PortChip.label(for: five) == ":53000")
    }
}
