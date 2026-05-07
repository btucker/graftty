// Tests/GrafttyKitTests/Ports/PortBindingTests.swift
import Testing
@testable import GrafttyKit

@Suite("PortBinding")
struct PortBindingTests {
    @Test("PortBinding equality keys on (port, scope, pid, processName)")
    func equality() {
        let a = PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 100)
        let b = PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 100)
        let c = PortBinding(port: 3000, scope: .lan,      processName: "node", pid: 100)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("BindScope is Sendable + has both cases")
    func scopeCases() {
        #expect(BindScope.loopback != BindScope.lan)
    }
}
