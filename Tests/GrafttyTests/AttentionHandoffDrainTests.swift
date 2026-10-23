import Foundation
import Testing
import GrafttyKit
@testable import Graftty

/// A save the test completes by hand, so a drain can be held mid-save.
@MainActor
private final class GatedSave {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0

    func save() async {
        started += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func finishAll() {
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }
}

@MainActor
private func makeHandoff() throws -> (AttentionFileHandoff, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("attention-drain-\(UUID().uuidString)", isDirectory: true)
    let handoff = AttentionFileHandoff(rootDirectory: root)
    try handoff.progress(worktree: "/repo", agentID: "codex-1", runtime: .codex, sessionID: nil)
    return (handoff, root)
}

/// Bounded wait on the main actor.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// REMOTE-23.10 at the app level: the save is now deferred off-main, so the
/// drain must not delete an event file until its result is on disk.
@Suite("Attention handoff drain keeps event files until the state save lands")
@MainActor
struct AttentionHandoffDrainTests {

    @Test func aFailedSaveLeavesTheEventForRetry() async throws {
        let (handoff, root) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: root) }
        struct DiskFull: Error {}
        let drain = AttentionHandoffDrain(handoff: handoff, apply: { _ in }, persist: { throw DiskFull() })

        await drain.drain()

        #expect(try handoff.takeActivities { _ in }.count == 1, "the event was deleted although its save failed")
    }

    @Test func aSuccessfulSaveRemovesTheEvent() async throws {
        let (handoff, root) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: root) }
        var applied = 0
        let drain = AttentionHandoffDrain(handoff: handoff, apply: { _ in applied += 1 }, persist: {})

        await drain.drain()

        #expect(applied == 1)
        #expect(try handoff.takeActivities { _ in }.isEmpty)
    }

    @Test func aDrainRequestedDuringTheSaveDoesNotReapplyTheBatch() async throws {
        let (handoff, root) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: root) }
        let save = GatedSave()
        var applied = 0
        let drain = AttentionHandoffDrain(handoff: handoff, apply: { _ in applied += 1 }, persist: { await save.save() })

        let first = Task { await drain.drain() }
        await waitUntil { save.started == 1 }
        // The observer fires again (file write or its 1 s timer) mid-save.
        var secondReturned = false
        let second = Task {
            await drain.drain()
            secondReturned = true
        }
        await waitUntil { secondReturned || save.started == 2 }
        save.finishAll()
        await first.value
        save.finishAll()
        await second.value

        #expect(applied == 1, "the batch was applied again while its save was in flight")
    }
}
