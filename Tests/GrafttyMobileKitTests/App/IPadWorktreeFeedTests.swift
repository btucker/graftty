#if canImport(UIKit)
import Foundation
import Observation
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@MainActor
@Suite("@spec IPAD-1.24: While the iPad layout displays a paired host, the application shall apply the host's pushed panes-state frames to the shared worktree state from outside the split view's columns, so the collapsed-sidebar attention indicator (IPAD-1.11) stays current without the sidebar list on screen.", .serialized)
struct IPadWorktreeFeedTests {
    private func hostValue(_ label: String) -> Host {
        Host(label: label, baseURL: URL(string: "https://\(label).local")!)
    }

    /// The modifier on an otherwise empty hosted view. The layout's split view
    /// isn't hosted: on CI's iPhone simulators it can relayout on every frame.
    private func mount(appState: IPadAppState, hostID: UUID, feed: MultiHostFeed) -> UIWindow {
        let view = Color.clear.modifier(IPadWorktreeFeed(hostID: hostID, feed: feed, appState: appState) { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func appState() throws -> IPadAppState {
        IPadAppState(defaults: try #require(UserDefaults(suiteName: "ipad-feed-\(UUID())")))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test("Pushed frames reach shared state outside the split view", .timeLimit(.minutes(1)))
    func pushedFramesReachSharedStateOutsideTheSplitView() async throws {
        let host = hostValue("mac")
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        let feed = MultiHostFeed(coordinator: nil, updates: { _ in frames.stream })
        feed.setHosts([host])
        let observation = Task { await feed.observe() }
        defer { observation.cancel(); frames.continuation.finish() }
        let state = try appState()
        let window = mount(appState: state, hostID: host.id, feed: feed)
        defer { window.isHidden = true }
        frames.continuation.yield(.frame(.snapshot(Self.rows)))
        try await waitUntil { state.latestWorktrees == Self.rows }
        #expect(state.anyWorktreeHasAttention)
    }

    @Test("@spec IPAD-1.25: When the iPad layout starts observing a paired host's pushed panes-state frames, the application shall recompute the shared worktree state from the first frame even if its rows equal state seeded before observation.", .timeLimit(.minutes(1)))
    func firstFrameRecomputesRowsSeededBeforeObservation() async throws {
        let host = hostValue("mac")
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        let feed = MultiHostFeed(coordinator: nil, updates: { _ in frames.stream })
        feed.setHosts([host])
        let observation = Task { await feed.observe() }
        defer { observation.cancel(); frames.continuation.finish() }
        let state = try appState()
        state.latestWorktrees = Self.rows
        state.anyWorktreeHasAttention = false
        let window = mount(appState: state, hostID: host.id, feed: feed)
        defer { window.isHidden = true }
        frames.continuation.yield(.frame(.snapshot(Self.rows)))
        try await waitUntil { state.anyWorktreeHasAttention }
    }

    @Test("@spec IPAD-1.34: While a different host's worktree is selected, the application shall leave shared worktree state alone when other hosts push frames.", .timeLimit(.minutes(1)))
    func otherHostsFramesLeaveSelectionAlone() async throws {
        let selected = hostValue("mac"), other = hostValue("box")
        let selectedFrames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        let otherFrames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        let feed = MultiHostFeed(coordinator: nil, updates: { $0.id == selected.id ? selectedFrames.stream : otherFrames.stream })
        feed.setHosts([selected, other])
        let observation = Task { await feed.observe() }
        defer { observation.cancel(); selectedFrames.continuation.finish(); otherFrames.continuation.finish() }
        let state = try appState()
        let window = mount(appState: state, hostID: selected.id, feed: feed)
        defer { window.isHidden = true }
        otherFrames.continuation.yield(.frame(.snapshot(Self.rows)))
        try await waitUntil { feed.state.isLive(other.id) }
        #expect(state.latestWorktrees.isEmpty)
    }

    @Test("The collapsed-sidebar indicator covers every host, not only the selected one", .timeLimit(.minutes(1)))
    func indicatorCoversEveryHost() async throws {
        let selected = hostValue("mac"), other = hostValue("box")
        let frames = AsyncStream<RemoteWorktreeUpdate>.makeStream()
        let feed = MultiHostFeed(coordinator: nil, updates: { $0.id == other.id ? frames.stream : nil })
        feed.setHosts([selected, other])
        let observation = Task { await feed.observe() }
        defer { observation.cancel(); frames.continuation.finish() }
        let state = try appState()
        let window = mount(appState: state, hostID: selected.id, feed: feed)
        defer { window.isHidden = true }
        frames.continuation.yield(.frame(.snapshot(Self.rows)))
        try await waitUntil { state.anyWorktreeHasAttention }
        #expect(state.latestWorktrees.isEmpty)
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

    @Test("@spec IOS-10.10: When a paired host pushes a worktree frame equal to the one the feed already holds, the application shall leave the feed's state unwritten, so views observing it are not redrawn by a repeated frame.")
    func repeatedFrameLeavesFeedStateUnwritten() {
        let host = hostValue("mac")
        let feed = MultiHostFeed(coordinator: nil, updates: { _ in nil })
        feed.setHosts([host])
        feed.receive(.frame(.snapshot(Self.rows)), from: host)
        func track() -> Flag {
            let invalidated = Flag()
            withObservationTracking { _ = feed.state } onChange: { invalidated.set() }
            return invalidated
        }
        let repeated = track()
        feed.receive(.frame(.snapshot(Self.rows)), from: host)
        #expect(!repeated.isSet)

        let changed = track()
        feed.receive(.frame(.snapshot([])), from: host)
        #expect(changed.isSet)
        #expect(feed.state.rows.isEmpty)
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
}
#endif
