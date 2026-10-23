#if canImport(UIKit)
import CoreFoundation
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
import XCTest
@testable import GrafttyMobileKit

@MainActor
final class LayoutPassHost<Content: View>: UIHostingController<Content> {
    var passes = 0
    var limit = 24
    var onLimit: (() -> Void)?
    var onTransitionComplete: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        passes += 1
        if passes == limit + 1 { onLimit?() }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            let callback = self?.onTransitionComplete
            self?.onTransitionComplete = nil
            callback?()
        }
    }
}

@MainActor
final class SplitLayoutFixture {
    private let suite = "ipad-layout-\(UUID())"
    private let storeURL: URL
    let defaults: UserDefaults
    let store: HostStore
    let state: IPadAppState
    let gate = BiometricGate(authenticator: UnlockedAuthenticator())
    let notifications: MobileAgentNotifications

    init(sidebarShown: Bool, hasHost: Bool) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        store = HostStore(storeURL: storeURL)
        let host = try store.add(Host(label: "mac", baseURL: URL(string: "http://127.0.0.1:9")!))
        state = IPadAppState(defaults: defaults)
        state.select(hostID: hasHost ? host.id : nil, worktreePath: nil, paneID: nil)
        state.columnVisibility = sidebarShown ? .all : .detailOnly
        notifications = MobileAgentNotifications(defaults: defaults)
    }

    func unlock() async {
        gate.applicationWillEnterForeground()
        await gate.authenticateOnActivation()
    }

    var root: some View {
        RootView(hostStore: store, gate: gate, notifications: notifications,
            appState: state, notificationIO: .init(fetch: { _ in [] }, reopen: { _, _ in }))
            .environment(\.scenePhase, .active)
            .defaultAppStorage(defaults)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: storeURL)
    }

    private struct UnlockedAuthenticator: BiometricAuthenticator {
        func authenticate() async -> Result<Void, Error> { .success(()) }
    }
}

/// Sample after UIKit's ordinary commit observers. Keep a synchronous counter
/// in the host, since an observer cannot interrupt a commit that never finishes.
@MainActor
func observeNaturalLayouts(passes: @escaping @MainActor () -> Int) async throws -> [Int] {
    let sampler = LayoutFrameSampler(passes: passes)
    sampler.start()
    defer { sampler.stop() }
    let result = await XCTWaiter.fulfillment(of: [sampler.finished], timeout: 10)
    try #require(result == .completed)
    return sampler.counts
}

@MainActor
private final class LayoutFrameSampler: NSObject {
    let finished = XCTestExpectation(description: "Twelve rendered layout frames")
    var counts: [Int] = []
    private let passes: @MainActor () -> Int
    private var sampleDue = false
    private var displayLink: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var firstSampleAt: ContinuousClock.Instant?

    init(passes: @escaping @MainActor () -> Int) { self.passes = passes }

    func start() {
        observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        displayLink = CADisplayLink(target: self, selector: #selector(frame))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func frame() { sampleDue = true }

    private func sample() {
        guard sampleDue else { return }
        sampleDue = false
        let now = ContinuousClock.now
        if firstSampleAt == nil { firstSampleAt = now }
        counts.append(passes())
        // Include the initial 250ms sidebar-width persistence debounce. Frame
        // rate is a hint, so check elapsed observation too. The synchronous
        // host counter, rather than this observation interval, detects storms.
        if counts.count >= 12, let firstSampleAt,
           firstSampleAt.duration(to: now) >= .milliseconds(300) {
            stop()
            finished.fulfill()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
    }
}
#endif
