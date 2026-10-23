import Foundation
import SwiftUI
import GrafttyKit

extension GrafttyApp {
    /// Tests bind a recording persister here so router and service paths
    /// never touch the real `~/Library/Application Support/Graftty`.
    @TaskLocal static var appStatePersisterOverride: AppStatePersister?

    /// A test host (XCTest is loaded) gets a per-process temp directory, so a
    /// test that forgets `$appStatePersisterOverride` cannot overwrite the
    /// developer's live `state.json` once the trailing save fires.
    static let sharedAppStatePersisterDirectory: URL = {
        guard NSClassFromString("XCTestCase") != nil else { return AppState.defaultDirectory }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "graftty-test-host-state-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
        )
    }()

    private static let sharedAppStatePersister = AppStatePersister(directory: sharedAppStatePersisterDirectory)

    /// Process-wide owner of `state.json` writes (PERSIST-2.3).
    static var appStatePersister: AppStatePersister {
        appStatePersisterOverride ?? sharedAppStatePersister
    }

    /// Schedules a coalesced, off-main save of `state`. The scene-level
    /// `.onChange` handles normal mutations; background services also call
    /// this directly so their changes are saved even if no SwiftUI observer
    /// runs while no window is open (LAYOUT-5.1).
    static func persistAppState(_ state: AppState) {
        appStatePersister.markDirty(state)
    }

    /// Writes `state` (after any in-flight write) before returning, for
    /// replies a CLI hook or paired device may act on by reading
    /// `state.json` (PERSIST-2.5). Marking and flushing in one main-actor
    /// turn guarantees the flush writes this snapshot or a newer one.
    static func persistAppStateNow(_ state: AppState) async throws {
        let persister = appStatePersister
        persister.markDirty(state)
        try await persister.flushNow()
    }

    /// Schedules a save when `appState` no longer equals `before`. Mutators
    /// reachable with no window open (socket, paired devices, terminal
    /// callbacks, timers) capture `before` and call this from a `defer`,
    /// because the window's `.onChange` does not exist then (#604).
    static func persistAppStateIfChanged(_ appState: Binding<AppState>, from before: AppState) {
        let after = appState.wrappedValue
        if after != before { persistAppState(after) }
    }

    /// Runs `body` and schedules a save if it changed `appState`. For
    /// mutations a paired device makes while no Mac window may be open
    /// (#604).
    @discardableResult
    static func persistingChanges<T>(to appState: Binding<AppState>, _ body: () -> T) -> T {
        let before = appState.wrappedValue
        defer { persistAppStateIfChanged(appState, from: before) }
        return body()
    }

    /// Writes `state` (after any in-flight write) on the calling thread. For
    /// `applicationWillTerminate` (PERSIST-2.6) and the CLI agent-launch
    /// replies (PERSIST-2.5), which must not suspend before replying: a
    /// suspended worktree create lets a same-ID retry hit its placeholder
    /// (AGENT-5.8). Everything else uses `persistAppState` or
    /// `persistAppStateNow`.
    static func persistAppStateSynchronously(_ state: AppState) throws {
        appStatePersister.markDirty(state)
        try appStatePersister.flushSynchronously()
    }
}
