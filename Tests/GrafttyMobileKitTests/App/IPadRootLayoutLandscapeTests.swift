#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
import XCTest
@testable import GrafttyMobileKit

/// Run this suite alone on iPhone 17 Pro Max with the test-target environment
/// GRAFTTY_RUN_NATIVE_IPAD_LAYOUT=1. CI keeps its iPhone 17 destination.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_RUN_NATIVE_IPAD_LAYOUT"] == "1"))
struct IPadRootLayoutLandscapeTests {
    @Test(arguments: [true, false], [true, false])
    func retainedRootViewRotates(sidebarShown: Bool, hasHost: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let blank = LayoutPassHost(rootView: Color.clear)
        window.rootViewController = blank
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        if !scene.interfaceOrientation.isPortrait {
            let completed = XCTestExpectation(description: "Portrait transition completed")
            blank.onTransitionComplete = { completed.fulfill() }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                Issue.record("Portrait request failed: \(error)")
                completed.fulfill()
            }
            let result = await XCTWaiter.fulfillment(of: [completed], timeout: 10)
            try #require(result == .completed)
        }
        try #require(scene.interfaceOrientation.isPortrait)
        try #require(window.traitCollection.horizontalSizeClass == .compact)
        let fixture = try SplitLayoutFixture(sidebarShown: sidebarShown, hasHost: hasHost)
        defer { fixture.cleanUp() }
        await fixture.unlock()
        let host = LayoutPassHost(rootView: fixture.root)
        host.limit = 1024
        host.onLimit = { [weak window] in window?.isHidden = true; window?.rootViewController = nil }
        window.rootViewController = host
        let startup = try await observeNaturalLayouts { host.passes }
        try #require(host.passes > 0 && host.passes <= 1024)
        try #require(Set(startup.suffix(3)).count == 1)

        // Keep this exact root/controller across rotation. Animation can perform
        // finite extra work; the larger emergency guard bounds that phase.
        host.passes = 0
        let completed = XCTestExpectation(description: "Retained root landscape transition completed")
        var transitionPending = true
        var overflowed = false
        host.onLimit = { [weak window] in
            overflowed = true
            window?.isHidden = true
            window?.rootViewController = nil
            if transitionPending { transitionPending = false; completed.fulfill() }
        }
        host.onTransitionComplete = {
            if transitionPending { transitionPending = false; completed.fulfill() }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { error in
            Issue.record("Landscape request failed: \(error)")
            if transitionPending { transitionPending = false; completed.fulfill() }
        }
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 10)
        let rotationPasses = host.passes
        print("648 native rotation: shown=\(sidebarShown) hasHost=\(hasHost) startup=\(startup) rotationPasses=\(rotationPasses) overflowed=\(overflowed)")
        try #require(result == .completed && !overflowed)
        try #require(rotationPasses > 0)
        try #require(scene.interfaceOrientation.isLandscape)
        try #require(window.traitCollection.horizontalSizeClass == .regular)
        try #require(window.traitCollection.verticalSizeClass == .compact)
        host.onTransitionComplete = nil
        host.passes = 0
        host.limit = 24
        let counts = try await observeNaturalLayouts { host.passes }
        print("648 native settled: shown=\(sidebarShown) hasHost=\(hasHost) passes=\(counts) scene=\(scene.coordinateSpace.bounds) window=\(window.bounds) supported=\(host.supportedInterfaceOrientations.rawValue) navigationWidth=\(fixture.state.navigationWindowWidth) safeAreaFrame=\(host.view.safeAreaLayoutGuide.layoutFrame) sidebarWidth=\(fixture.state.sidebarWidth)")
        #expect(host.traitCollection.horizontalSizeClass == .regular)
        #expect(abs(fixture.state.navigationWindowWidth - host.view.safeAreaLayoutGuide.layoutFrame.width) < 1)
        #expect(host.passes <= 24)
        #expect(Set(counts.suffix(3)).count == 1)
    }
}
#endif
