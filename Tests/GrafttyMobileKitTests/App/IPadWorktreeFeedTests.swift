#if canImport(UIKit)
import Foundation
import Observation
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
import XCTest
@testable import GrafttyMobileKit

@MainActor
@Suite("@spec IPAD-1.24: While the iPad layout displays a paired host, the application shall apply the host's pushed panes-state frames to the shared worktree state from outside the split view's columns, so the collapsed-sidebar attention indicator (IPAD-1.11) stays current without the sidebar list on screen.", .serialized)
struct IPadWorktreeFeedTests {
    // The feed is hosted without the layout's NavigationSplitView: on the
    // iPhone simulators CI runs on, a hosted split view can relayout on
    // every frame with the sidebar shown or collapsed (#646, #648, #657).
    @Test("Pushed frames reach shared state outside the split view", .timeLimit(.minutes(1)))
    func pushedFramesReachSharedStateOutsideTheSplitView() async throws {
        let feed = try MountedFeed()
        defer { feed.unmount() }

        feed.frames.publish(.snapshot(Self.rows))
        try await feed.waitForAppliedFrame()
        #expect(feed.appState.latestWorktrees == Self.rows)
        #expect(feed.appState.anyWorktreeHasAttention)
        #expect(feed.applied == [Self.rows])
    }

    @Test("@spec IPAD-1.25: When the iPad layout starts observing a paired host's pushed panes-state frames, the application shall recompute the shared worktree state from the first frame even if its rows equal the rows already stored, such as rows seeded by a notification or recent-pane activation, so the collapsed-sidebar attention indicator (IPAD-1.11) reflects them.", .timeLimit(.minutes(1)))
    func firstFrameRecomputesRowsSeededBeforeObservation() async throws {
        // RootView.applyActivationTarget stores fresh rows without
        // recomputing the indicator; the host's latest frame repeats them.
        let feed = try MountedFeed { appState in
            appState.latestWorktrees = Self.rows
            appState.anyWorktreeHasAttention = false
        }
        defer { feed.unmount() }

        feed.frames.publish(.snapshot(Self.rows))
        try await feed.waitForAppliedFrame()
        #expect(feed.appState.anyWorktreeHasAttention)
    }

    @Test("The root layout attaches the matching feed outside its columns and retains each settlement call")
    func rootLayoutComposesTheFeedAndSettlement() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/GrafttyMobileKit/App/IPadRootLayout.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "public var body: some View {")?.upperBound)
        let end = try #require(source.range(of: "// MARK: - Selection helpers", range: start..<source.endIndex)?.lowerBound)
        // This source-level guard covers wiring without cold-mounting the split
        // view. Ignore comments and formatting, not just a matching type name.
        let body = String(source[start..<end])
            .replacingOccurrences(of: #"(?s)/\*.*?\*/|//[^\n]*"#, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace }
        let columnsEnded = try #require(body.range(of: ".navigationSplitViewStyle(.balanced)")?.upperBound)
        let feed = try #require(body.range(of: ".modifier(IPadWorktreeFeed(host:remote?.host,updates:remote?.providers.updates,appState:appState){listin"))
        #expect(feed.lowerBound > columnsEnded)
        // The modifier must attach after the outer ZStack closes. Ordering
        // alone also accepts moving both modifiers into the detail closure.
        let enclosingClosures = body[..<feed.lowerBound].reduce(0) { depth, character in
            depth + (character == "{" ? 1 : character == "}" ? -1 : 0)
        }
        #expect(enclosingClosures == 0)
        let settlementEnd = try #require(body.range(of: "})", range: feed.upperBound..<body.endIndex)?.lowerBound)
        #expect(String(body[feed.upperBound..<settlementEnd]) ==
            "reconcileMobileCloseProjections(in:list)resolveLegacyMobileSplit(in:list)applyPendingMobileCreatedFocus(in:list)")
    }

    @Test("A duplicate frame is consumed without another callback, then a changed frame is applied", .timeLimit(.minutes(1)))
    func duplicateThenChangedFrames() async throws {
        let feed = try MountedFeed()
        defer { feed.unmount() }
        try await feed.publishAndWait(Self.rows)
        // Acknowledge forwarding so the latest-value broadcast cannot coalesce
        // the duplicate away before the feed's unbounded stream receives it.
        try await feed.publishUntilForwarded(Self.rows)
        try await feed.publishAndWait([])
        #expect(feed.appState.latestWorktrees.isEmpty)
        #expect(!feed.appState.anyWorktreeHasAttention)
        #expect(feed.applied == [Self.rows, []])
    }

    @Test("Switching hosts cancels the old subscription and applies only the new host's frames", .timeLimit(.minutes(1)))
    func hostSwitchRestartsTheFeed() async throws {
        let feed = try MountedFeed()
        defer { feed.unmount() }
        try await feed.publishAndWait(Self.rows)
        let oldHostID = feed.host.id
        let oldFrames = feed.frames
        let nextHost = Host(label: "second mac", baseURL: URL(string: "http://127.0.0.1:9")!)
        feed.expectSubscription()
        feed.expectCancellation()
        feed.changeHost(to: nextHost)
        try await feed.waitForSubscription()
        try await feed.waitForCancellation()
        oldFrames.publish(.snapshot(Self.rows))
        try await feed.publishAndWait([])
        #expect(feed.requestedHosts == [oldHostID, nextHost.id])
        #expect(feed.appState.selectedHostId == nextHost.id)
        #expect(feed.appState.latestWorktrees.isEmpty)
        #expect(feed.applied == [Self.rows, []])
    }

    @Test("Background readiness cancels observation and resuming recomputes the replayed first frame", .timeLimit(.minutes(1)))
    func readinessRestartRecomputesTheFirstFrame() async throws {
        let feed = try MountedFeed()
        defer { feed.unmount() }
        try await feed.publishAndWait(Self.rows)
        feed.expectCancellation()
        feed.changeScene(to: .background)
        try await feed.waitForCancellation()
        #expect(feed.requestedHosts == [feed.host.id])
        feed.appState.anyWorktreeHasAttention = false
        feed.expectSubscription()
        feed.expectAppliedFrame()
        feed.changeScene(to: .active)
        try await feed.waitForSubscription()
        try await feed.waitForAppliedFrame()
        #expect(feed.requestedHosts == [feed.host.id, feed.host.id])
        #expect(feed.appState.anyWorktreeHasAttention)
        #expect(feed.applied == [Self.rows, Self.rows])
    }

    @Test("@spec IPAD-1.26: When the iPad layout applies a pushed panes-state frame whose rows equal the shared worktree state, the application shall leave the shared rows and attention indicator unwritten, so views observing them are not invalidated by a repeated frame.")
    func equalFrameLeavesSharedStateUnwritten() throws {
        let suite = "ipad-feed-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = IPadAppState(defaults: defaults)
        IPadRootLayout.onWorktreeListChanged(appState: appState, list: Self.rows)

        func track() -> Flag {
            let invalidated = Flag()
            withObservationTracking {
                _ = appState.latestWorktrees
                _ = appState.anyWorktreeHasAttention
            } onChange: { invalidated.set() }
            return invalidated
        }
        let repeated = track()
        IPadRootLayout.onWorktreeListChanged(appState: appState, list: Self.rows)
        #expect(!repeated.isSet)

        // The tracking does see a frame that changes the rows.
        let changed = track()
        IPadRootLayout.onWorktreeListChanged(appState: appState, list: [])
        #expect(changed.isSet)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private static let rows = [WorktreePanes(path: "/repo/review", displayName: "review", repoDisplayName: "repo",
        displayBranch: "review", state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
        attentionText: "Needs review", layout: .leaf(sessionName: "s", title: "shell",
            attentionText: nil, isBusy: false, attentionSource: nil))]

    /// The layout's worktree feed on an otherwise empty hosted view, for a
    /// selected host whose pushed frames come from `frames`.
    @MainActor
    private final class MountedFeed {
        let appState: IPadAppState
        var host: Host { configuration.host }
        var frames: LatestValueBroadcast<PanesStateMessage> { broadcast(for: host.id) }
        /// The rows handed to the layout after each applied frame.
        private(set) var applied: [[WorktreePanes]] = []
        private(set) var requestedHosts: [UUID] = []
        private let configuration: FeedConfiguration
        private var broadcasts: [UUID: LatestValueBroadcast<PanesStateMessage>] = [:]
        private var appliedFrame = XCTestExpectation(description: "The hosted feed applied the pushed frame")
        private var subscribed = XCTestExpectation(description: "The feed requested its host's stream")
        private var cancelled: XCTestExpectation?
        private var forwarded: XCTestExpectation?
        private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        private let defaultsSuite = "ipad-feed-\(UUID())"
        private let defaults: UserDefaults

        init(prepare: (IPadAppState) -> Void = { _ in }) throws {
            let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            self.defaults = defaults
            let host = Host(label: "mac", baseURL: URL(string: "http://127.0.0.1:9")!)
            configuration = FeedConfiguration(host: host)
            appState = IPadAppState(defaults: defaults)
            appState.sidebarNavigation = .init(prefix: "sidebar.mobile", defaults: defaults, collapsed: true)
            appState.select(hostID: host.id, worktreePath: nil, paneID: nil)
            prepare(appState)

            let pushed = RemoteWorktreeUpdatesProvider { [weak self] host in
                self?.updates(for: host)
            }
            let root = FeedHarness(configuration: configuration, appState: appState, pushed: pushed) { [weak self] list in
                self?.applied.append(list)
                self?.appliedFrame.fulfill()
            }
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
        }

        func unmount() {
            cancelled = nil
            forwarded = nil
            window.isHidden = true
            window.rootViewController = nil
            for frames in broadcasts.values { frames.finish() }
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        func expectAppliedFrame() { appliedFrame = XCTestExpectation(description: "The feed applied the next frame") }
        func expectSubscription() { subscribed = XCTestExpectation(description: "The feed requested the next stream") }
        func expectCancellation() { cancelled = XCTestExpectation(description: "The feed cancelled its stream") }
        func changeHost(to host: Host) {
            appState.select(hostID: host.id, worktreePath: nil, paneID: nil)
            configuration.host = host
        }
        func changeScene(to phase: ScenePhase) { configuration.phase = phase }
        func waitForSubscription() async throws { try await wait(subscribed) }
        func waitForCancellation() async throws { try await wait(try #require(cancelled)) }
        func waitForAppliedFrame() async throws {
            try await wait(appliedFrame)
        }
        func publishAndWait(_ rows: [WorktreePanes]) async throws {
            expectAppliedFrame()
            try await publishUntilForwarded(rows)
            try await waitForAppliedFrame()
        }
        func publishUntilForwarded(_ rows: [WorktreePanes]) async throws {
            let event = XCTestExpectation(description: "The source enqueued the frame for the feed")
            forwarded = event
            frames.publish(.snapshot(rows))
            defer { forwarded = nil }
            try await wait(event)
        }
        private func wait(_ event: XCTestExpectation) async throws {
            let result = await XCTWaiter.fulfillment(of: [event], timeout: 3)
            try #require(result == .completed)
        }

        private func broadcast(for hostID: UUID) -> LatestValueBroadcast<PanesStateMessage> {
            if let existing = broadcasts[hostID] { return existing }
            let frames = LatestValueBroadcast<PanesStateMessage>()
            broadcasts[hostID] = frames
            return frames
        }

        private func updates(for host: Host) -> AsyncStream<RemoteWorktreeUpdate> {
            requestedHosts.append(host.id)
            subscribed.fulfill()
            let frames = broadcast(for: host.id)
            return AsyncStream(bufferingPolicy: .unbounded) { continuation in
                let task = Task { @MainActor [weak self] in
                    for await frame in frames.updates() {
                        continuation.yield(.frame(frame))
                        self?.forwarded?.fulfill()
                    }
                    continuation.finish()
                }
                continuation.onTermination = { [weak self] _ in
                    task.cancel()
                    Task { @MainActor [weak self] in self?.cancelled?.fulfill() }
                }
            }
        }
    }

    // Observable emits a file-scope conformance for this nested test type.
    @MainActor @Observable
    fileprivate final class FeedConfiguration {
        var host: Host
        var phase: ScenePhase = .active
        init(host: Host) { self.host = host }
    }

    /// Keep the same mounted view while the inputs to the real modifier change.
    @MainActor
    private struct FeedHarness: View {
        let configuration: FeedConfiguration
        let appState: IPadAppState
        let pushed: RemoteWorktreeUpdatesProvider
        let didApply: @MainActor ([WorktreePanes]) -> Void

        var body: some View {
            let host = configuration.host
            let remote = RemoteWorktreeProviders(coordinator: nil, host: host, worktreeUpdates: pushed)
            Color.clear
                .modifier(IPadWorktreeFeed(host: host, updates: remote.updates, appState: appState, didApply: didApply))
                .environment(\.scenePhase, configuration.phase)
        }
    }
}
#endif
