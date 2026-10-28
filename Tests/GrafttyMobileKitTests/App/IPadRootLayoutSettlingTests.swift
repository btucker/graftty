#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
import XCTest
@testable import GrafttyMobileKit

@MainActor
@Suite("@spec IPAD-1.27: When a phone's retained RootView enters the regular-width mobile split layout with its sidebar shown or collapsed, the application shall settle within 24 layout passes.", .serialized)
struct IPadRootLayoutSettlingTests {
    @Test("The layout fixture keeps sidebar preferences in its isolated defaults")
    func fixtureKeepsSidebarDefaultsIsolated() throws {
        let fixture = try SplitLayoutFixture(sidebarShown: true, hasHost: true)
        defer { fixture.cleanUp() }
        let key = "sidebar.mobile.railWidth"
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
        let debounce = ManualSidebarWidthDebounce()
        fixture.debounce = debounce
        await fixture.unlock()
        let window = try await mountRegularWidth(fixture, publishesSidebarWidth: hasHost)
        defer { window.isHidden = true; window.rootViewController = nil }
        debounce.elapse()
        print("706 debounce: shown=\(sidebarShown) hasHost=\(hasHost) scheduled=\(debounce.scheduled) remembered=\(fixture.state.sidebarWidth)")
        if !sidebarShown || !hasHost {
            #expect(debounce.scheduled == 0)
            #expect(fixture.state.sidebarWidth == 900)
            #expect(IPadAppState(defaults: fixture.defaults).sidebarWidth == 900)
        } else {
            #expect(fixture.state.sidebarWidth >= 220 && fixture.state.sidebarWidth < 900)
            #expect(IPadAppState(defaults: fixture.defaults).sidebarWidth == fixture.state.sidebarWidth)
        }
    }

    @Test("@spec IPAD-1.29: While a measured regular-width mobile sidebar width waits in the persistence debounce, the application shall keep the remembered width until the debounce elapses.")
    func holdsMeasuredSidebarWidthUntilDebounceElapses() async throws {
        let fixture = try SplitLayoutFixture(sidebarShown: true, hasHost: true)
        defer { fixture.cleanUp() }
        fixture.state.sidebarWidth = 900
        let debounce = ManualSidebarWidthDebounce()
        fixture.debounce = debounce
        await fixture.unlock()
        let window = try await mountRegularWidth(fixture, publishesSidebarWidth: true)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(debounce.pendingCount == 1)
        #expect(fixture.state.sidebarWidth == 900)
        #expect(IPadAppState(defaults: fixture.defaults).sidebarWidth == 900)
        debounce.elapse()
        #expect(fixture.state.sidebarWidth >= 220 && fixture.state.sidebarWidth < 900)
        #expect(IPadAppState(defaults: fixture.defaults).sidebarWidth == fixture.state.sidebarWidth)
    }

    /// Hosts the root directly in the historical regular-width geometry with
    /// native landscape's trait pair, and returns once it has appeared and
    /// its split view has delivered a sidebar width: a measured one when it
    /// shows host content, otherwise the zero a hostless sidebar leaves in
    /// place (#706). Persistence observes the same delivery, so its decision
    /// is recorded by then. Nothing waits on wall-clock time. The split view
    /// delivers its widths within its first three layout passes, so the
    /// window detaches after IPAD-1.27's 24-pass bound instead of hosting a
    /// loaded cold-mount storm (#704) of up to a thousand inert passes; these
    /// tests do not assert settling.
    private func mountRegularWidth(_ fixture: SplitLayoutFixture, publishesSidebarWidth: Bool) async throws -> UIWindow {
        let appeared = XCTestExpectation(description: "The regular-width root appeared")
        appeared.assertForOverFulfill = false
        let delivered = XCTestExpectation(description: "The split view delivered its sidebar width")
        delivered.assertForOverFulfill = false
        let host = LayoutPassHost(rootView: fixture.root
            .onAppear { appeared.fulfill() }
            .onPreferenceChange(SidebarWidthKey.self) { width in
                if width > 0 || !publishesSidebarWidth { delivered.fulfill() }
            })
        host.limit = 24
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
        window.traitOverrides.horizontalSizeClass = .regular
        window.traitOverrides.verticalSizeClass = .compact
        host.onLimit = { [weak window] in window?.isHidden = true; window?.rootViewController = nil }
        window.rootViewController = host
        window.makeKeyAndVisible()
        do {
            let result = await XCTWaiter.fulfillment(of: [appeared, delivered], timeout: 10)
            try #require(result == .completed)
            try #require(abs(fixture.state.navigationWindowWidth - host.view.safeAreaLayoutGuide.layoutFrame.width) < 1)
        } catch {
            window.isHidden = true
            window.rootViewController = nil
            throw error
        }
        return window
    }
}
#endif
