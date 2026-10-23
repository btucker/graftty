#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@MainActor
@Suite("@spec IPAD-1.27: When a phone's retained RootView enters the regular-width mobile split layout with its sidebar shown or collapsed, the application shall settle within 24 layout passes.", .serialized)
struct IPadRootLayoutSettlingTests {
    @Test("The layout fixture keeps sidebar preferences in its isolated defaults")
    func fixtureKeepsSidebarDefaultsIsolated() throws {
        let fixture = try SplitLayoutFixture(sidebarShown: true, hasHost: true)
        defer { fixture.cleanUp() }
        let key = "sidebar.mobile.railWidth"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        fixture.state.sidebarNavigation.railExpandedWidth = 412
        #expect(fixture.defaults.double(forKey: key) == 412)
    }

    /// CI's iPhone 17 has compact native landscape width. Retain the production
    /// root while changing the hosted window to the historical regular geometry
    /// and native landscape's regular-width, compact-height trait pair.
    /// The opt-in scene-backed test separately covers native Pro Max rotation.
    /// Fresh-host counts include finite cold-start work tracked in #704; this
    /// assertion measures the retained production view after startup instead.
    @Test(arguments: [true, false], [true, false])
    func rootViewSettlesAfterRegularWidthTransition(sidebarShown: Bool, hasHost: Bool) async throws {
        let fixture = try SplitLayoutFixture(sidebarShown: sidebarShown, hasHost: hasHost)
        defer { fixture.cleanUp() }
        await fixture.unlock()
        let host = LayoutPassHost(rootView: fixture.root)
        host.limit = 1024
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.traitOverrides.horizontalSizeClass = .compact
        window.traitOverrides.verticalSizeClass = .regular
        host.onLimit = { [weak window] in window?.isHidden = true; window?.rootViewController = nil }
        defer { window.isHidden = true; window.rootViewController = nil }
        window.rootViewController = host
        window.makeKeyAndVisible()
        let startup = try await observeNaturalLayouts { host.passes }
        try #require(host.passes > 0 && host.passes <= 1024)
        try #require(Set(startup.suffix(3)).count == 1)
        host.passes = 0
        host.limit = 24
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        window.traitOverrides.horizontalSizeClass = .regular
        window.traitOverrides.verticalSizeClass = .compact
        let counts = try await observeNaturalLayouts { host.passes }
        print("648 RootView transition: shown=\(sidebarShown) hasHost=\(hasHost) startup=\(startup) passes=\(counts) window=\(window.bounds) navigationWidth=\(fixture.state.navigationWindowWidth) safeAreaFrame=\(host.view.safeAreaLayoutGuide.layoutFrame) sidebarWidth=\(fixture.state.sidebarWidth)")
        #expect(host.passes > 0 && host.passes <= 24)
        #expect(Set(counts.suffix(3)).count == 1)
        #expect(host.traitCollection.horizontalSizeClass == .regular)
        #expect(host.traitCollection.verticalSizeClass == .compact)
        #expect(abs(fixture.state.navigationWindowWidth - host.view.safeAreaLayoutGuide.layoutFrame.width) < 1)
    }
}
#endif
