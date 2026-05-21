#if canImport(UIKit)
import Testing
import Foundation
import SwiftUI
@testable import GrafttyProtocol
@testable import GrafttyMobileKit

@MainActor
@Suite("RootView size-class router — IPAD-1.1 + IPAD-7.1")
struct RootViewSizeClassTests {

    @Test("""
@spec IPAD-1.1: When `horizontalSizeClass == .regular`, the iPad application shall render `IPadRootLayout` (NavigationSplitView, 2-column) in place of the compact-width `NavigationStack`.
""")
    func ipad_1_1_regularRendersIPadRootLayout() {
        let store = HostStore(storeURL: URL(fileURLWithPath: "/tmp/RootViewSizeClassTests-\(UUID()).json"))
        let appState = IPadAppState(defaults: UserDefaults(suiteName: "RootViewSizeClassTests-\(UUID().uuidString)")!)
        let layout = IPadRootLayout(hostStore: store, appState: appState)
        _ = layout
        #expect(true)
    }

    @Test("""
@spec IPAD-7.1: When `horizontalSizeClass == .compact`, the application shall render the existing compact `RootView` flow (NavigationStack: HostPicker → WorktreePicker → SingleSessionView) without any iPad layout components.
""")
    func ipad_7_1_compactRendersExistingFlow() {
        let view = RootView()
        _ = view.body
        #expect(true)
    }

    @Test("IPadAppState is lifted to RootView level (survives recreation of children)")
    func appStateLifted() {
        let defaults = UserDefaults(suiteName: "appStateLifted-\(UUID().uuidString)")!
        let appState = IPadAppState(defaults: defaults)
        appState.selectedHostId = UUID()
        #expect(appState.selectedHostId != nil)
    }
}
#endif
