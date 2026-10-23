#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@MainActor
@Suite("IPadRootLayout worktree feed")
struct IPadWorktreeFeedTests {
    @Test("@spec IPAD-1.24: While the iPad layout displays a paired host, the application shall apply the host's pushed panes-state frames to the shared worktree state whether the sidebar column is shown or collapsed, so the collapsed-sidebar attention indicator (IPAD-1.11) stays current.", .timeLimit(.minutes(1)), arguments: [NavigationSplitViewVisibility.all, .detailOnly])
    func pushedFramesReachSharedStateInEveryColumnLayout(columns: NavigationSplitViewVisibility) async throws {
        let layout = try MountedLayout(columns: columns)
        defer { layout.unmount() }

        layout.frames.publish(.snapshot(Self.rows))
        try await waitUntil("pushed frame applied with \(columns)") { layout.appState.latestWorktrees == Self.rows }
        #expect(layout.appState.anyWorktreeHasAttention)
    }

    @Test("@spec IPAD-1.25: When the iPad layout starts observing a paired host's pushed panes-state frames, the application shall recompute the shared worktree state from the first frame even if its rows equal the rows already stored, such as rows seeded by a notification or recent-pane activation, so the collapsed-sidebar attention indicator (IPAD-1.11) reflects them.", .timeLimit(.minutes(1)))
    func firstFrameRecomputesRowsSeededBeforeObservation() async throws {
        // RootView.applyActivationTarget stores fresh rows without
        // recomputing the indicator; the host's latest frame repeats them.
        let layout = try MountedLayout(columns: .detailOnly) { appState in
            appState.latestWorktrees = Self.rows
            appState.anyWorktreeHasAttention = false
        }
        defer { layout.unmount() }

        layout.frames.publish(.snapshot(Self.rows))
        try await waitUntil("attention recomputed from the seeded rows") { layout.appState.anyWorktreeHasAttention }
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

    /// An `IPadRootLayout` hosted in a regular-width window whose selected
    /// host's pushed frames come from `frames`.
    @MainActor
    private struct MountedLayout {
        let appState: IPadAppState
        /// One source, a separate stream per subscriber.
        let frames: LatestValueBroadcast<PanesStateMessage>
        private let window: UIWindow
        private let defaults: UserDefaults
        private let defaultsSuite: String
        private let hostStoreURL: URL

        init(columns: NavigationSplitViewVisibility, prepare: (IPadAppState) -> Void = { _ in }) throws {
            defaultsSuite = "ipad-feed-\(UUID())"
            defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            hostStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-feed-\(UUID()).json")
            let hostStore = HostStore(storeURL: hostStoreURL)
            // A refused port, so the list's HTTP fallback fails at once.
            let host = try hostStore.add(Host(label: "mac", baseURL: URL(string: "http://127.0.0.1:9")!))
            appState = IPadAppState(defaults: defaults)
            appState.select(hostID: host.id, worktreePath: nil, paneID: nil)
            appState.columnVisibility = columns
            prepare(appState)

            let frames = LatestValueBroadcast<PanesStateMessage>()
            self.frames = frames
            let feed = RemoteWorktreeUpdatesProvider { _ in
                AsyncStream { continuation in
                    let task = Task {
                        for await frame in frames.updates() { continuation.yield(.frame(frame)) }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
            // A hosted controller has no active scene; live loading waits for one.
            let controller = UIHostingController(rootView: IPadRootLayout(hostStore: hostStore, appState: appState)
                .environment(\.remoteWorktreeUpdates, feed)
                .environment(\.scenePhase, .active))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
            window.traitOverrides.horizontalSizeClass = .regular
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }

        func unmount() {
            window.isHidden = true
            window.rootViewController = nil
            frames.finish()
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: hostStoreURL)
        }
    }

    /// Hosted SwiftUI tasks start asynchronously; wait for the condition with
    /// a bounded number of short pauses rather than a fixed delay.
    private func waitUntil(_ stage: String, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for \(stage)")
    }
}
#endif
