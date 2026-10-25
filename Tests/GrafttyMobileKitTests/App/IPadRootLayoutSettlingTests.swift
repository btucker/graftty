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
    @Test(.disabled("#731: cold first mount of the split view storms under load; see issue"), arguments: [true, false], [true, false])
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

    @Test("@spec IPAD-1.28: When the regular-width mobile sidebar is collapsed or has no host content, the application shall preserve the remembered expanded sidebar width through the persistence debounce.", arguments: [true, false], [true, false])
    func remembersExpandedSidebarWidth(sidebarShown: Bool, hasHost: Bool) async throws {
        let fixture = try SplitLayoutFixture(sidebarShown: sidebarShown, hasHost: hasHost)
        defer { fixture.cleanUp() }
        // Above the split view's maximum, so the visible case must persist
        // a new measurement rather than pass with the preseeded value.
        fixture.state.sidebarWidth = 900
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
        _ = try await observeNaturalLayouts { host.passes }
        try #require(host.passes > 0 && host.passes <= 1024)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        window.traitOverrides.horizontalSizeClass = .regular
        window.traitOverrides.verticalSizeClass = .compact
        // The natural-frame probe spans the real 250 ms persistence debounce.
        _ = try await observeNaturalLayouts { host.passes }
        try #require(abs(fixture.state.navigationWindowWidth - host.view.safeAreaLayoutGuide.layoutFrame.width) < 1)
        print("706 debounce: shown=\(sidebarShown) hasHost=\(hasHost) remembered=\(fixture.state.sidebarWidth)")
        if !sidebarShown || !hasHost {
            #expect(fixture.state.sidebarWidth == 900)
            #expect(IPadAppState(defaults: fixture.defaults).sidebarWidth == 900)
        } else {
            #expect(fixture.state.sidebarWidth >= 220 && fixture.state.sidebarWidth < 900)
            #expect(IPadAppState(defaults: fixture.defaults).sidebarWidth == fixture.state.sidebarWidth)
        }
    }

}
#endif
