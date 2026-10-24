#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
import XCTest
@testable import GrafttyMobileKit

@MainActor
@Suite("IPadRootLayout worktree feed")
struct IPadWorktreeFeedTests {
    // The feed is hosted without the layout's NavigationSplitView: on the
    // iPhone simulators CI runs on, a hosted split view can relayout on
    // every frame with the sidebar shown or collapsed (#646, #648, #657).
    @Test("@spec IPAD-1.24: While the iPad layout displays a paired host, the application shall apply the host's pushed panes-state frames to the shared worktree state from outside the split view's columns, so the collapsed-sidebar attention indicator (IPAD-1.11) stays current without the sidebar list on screen.", .timeLimit(.minutes(1)))
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
        /// One source, a separate stream per subscriber.
        let frames = LatestValueBroadcast<PanesStateMessage>()
        /// The rows handed to the layout after each applied frame.
        private(set) var applied: [[WorktreePanes]] = []
        private let appliedFrame = XCTestExpectation(description: "The hosted feed applied the pushed frame")
        private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        private let defaultsSuite = "ipad-feed-\(UUID())"

        init(prepare: (IPadAppState) -> Void = { _ in }) throws {
            let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            let host = Host(label: "mac", baseURL: URL(string: "http://127.0.0.1:9")!)
            appState = IPadAppState(defaults: defaults)
            appState.select(hostID: host.id, worktreePath: nil, paneID: nil)
            prepare(appState)

            let frames = frames
            let pushed = RemoteWorktreeUpdatesProvider { _ in
                AsyncStream { continuation in
                    let task = Task {
                        for await frame in frames.updates() { continuation.yield(.frame(frame)) }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
            // Wired as the layout wires it: without a coordinator, the
            // injected feed stands in for pairing.
            let remote = RemoteWorktreeProviders(coordinator: nil, host: host, worktreeUpdates: pushed)
            let feed = IPadWorktreeFeed(host: host, updates: remote.updates, appState: appState) { [weak self] list in
                self?.applied.append(list)
                self?.appliedFrame.fulfill()
            }
            // A hosted controller has no active scene; the feed waits for one.
            window.rootViewController = UIHostingController(rootView: Color.clear
                .modifier(feed)
                .environment(\.scenePhase, .active))
            window.makeKeyAndVisible()
        }

        func unmount() {
            window.isHidden = true
            window.rootViewController = nil
            frames.finish()
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        }

        func waitForAppliedFrame() async throws {
            // The gate opens after shared state and applied rows are updated.
            // Keep the former polling budget as a failure bound, without pauses.
            let result = await XCTWaiter.fulfillment(of: [appliedFrame], timeout: 3)
            try #require(result == .completed)
        }
    }
}
#endif
