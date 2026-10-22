import Foundation
import GrafttyKit

extension GrafttyApp {
    /// Tests bind a recording persister here so router and service paths
    /// never touch the real `~/Library/Application Support/Graftty`.
    @TaskLocal static var appStatePersisterOverride: AppStatePersister?

    private static let sharedAppStatePersister = AppStatePersister(directory: AppState.defaultDirectory)

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
