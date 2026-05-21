import Testing
import SwiftUI
@testable import GrafttyProtocol

@Suite("SidebarWidthKey + persistSidebarWidth — shared sidebar width plumbing")
struct SidebarWidthPreferenceTests {

    @Test("reduce ignores zero candidates")
    func reduceIgnoresZero() {
        var value: Double = 240
        SidebarWidthKey.reduce(value: &value, nextValue: { 0 })
        #expect(value == 240)
    }

    @Test("reduce accepts non-zero candidates")
    func reduceAcceptsNonZero() {
        var value: Double = 240
        SidebarWidthKey.reduce(value: &value, nextValue: { 360 })
        #expect(value == 360)
    }

    @Test("reduce default value is zero")
    func defaultIsZero() {
        #expect(SidebarWidthKey.defaultValue == 0)
    }
}
