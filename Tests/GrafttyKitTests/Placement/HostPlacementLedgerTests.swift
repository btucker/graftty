import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite @MainActor
struct HostPlacementLedgerTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private var demand: HostPlacementDemand { .init(architecture: "arm64", cpus: 2, memoryBytes: 4 * 1024 * 1024 * 1024, diskBytes: 1024 * 1024 * 1024) }
    private func owner(_ byte: UInt8 = 1) throws -> RemoteMacConnectionSummary.ID {
        .init(deviceID: .init(value: "parent"), fingerprint: try .init(rawBytes: Data(repeating: byte, count: 32)))
    }
    private func intent(_ name: String = "task") -> HostPlacementIntent {
        .init(repositoryID: "/project", worktreeName: name, branchName: name, demand: demand)
    }
    private func sample() -> HostResourceSnapshot {
        .init(sampledAt: 999, architecture: "arm64", operatingSystem: "linux", cpuCount: 4, cpuUtilization: 0.1,
              memoryTotalBytes: 16 << 30, memoryAvailableBytes: 12 << 30, diskPath: "/project", diskAvailableBytes: 100 << 30,
              activeWorktrees: 0, pendingWorktreeOperations: 0, pendingPlacements: 0)
    }
    private func file() -> URL { URL.temporaryDirectory.appendingPathComponent("placement-\(UUID())/ledger.json") }

    @Test("@spec REMOTE-24.8: When concurrent or retried placement requests are accepted, the application shall reserve capacity and reuse operation identities to avoid duplicate allocations.")
    func durableAdmissionAccountsForConcurrentDemandAndRetries() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try HostPlacementLedger(fileURL: url)
        let id = UUID()
        let first = try ledger.admit(operationID: id, owner: owner(), intent: intent(), sample: sample(), at: now)
        #expect(first.state == .preparing)
        #expect(ledger.pendingCount == 1)
        #expect(try ledger.admit(operationID: id, owner: owner(), intent: intent(), sample: nil, at: now) == first)
        #expect(throws: (any Error).self) {
            try ledger.admit(operationID: UUID(), owner: owner(), intent: intent("second"), sample: sample(), at: now)
        }
        let restored = try HostPlacementLedger(fileURL: url)
        #expect(try restored.status(operationID: id, owner: owner())?.state == .outcomeUnknown)
        #expect(restored.pendingCount == 1)
        #expect(throws: (any Error).self) {
            try restored.admit(operationID: UUID(), owner: owner(), intent: intent("third"), sample: sample(), at: now)
        }
    }

    @Test func identityAndIntentCannotBeReplacedOnRetry() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try HostPlacementLedger(fileURL: url); let id = UUID()
        _ = try ledger.admit(operationID: id, owner: owner(), intent: intent(), sample: sample(), at: now)
        #expect(throws: (any Error).self) { try ledger.status(operationID: id, owner: owner(2)) }
        #expect(throws: (any Error).self) { try ledger.admit(operationID: id, owner: owner(2), intent: intent(), sample: sample(), at: now) }
        #expect(throws: (any Error).self) { try ledger.admit(operationID: id, owner: owner(), intent: intent("changed"), sample: sample(), at: now) }
    }

    @Test func completedResultSurvivesRestartAndDeletionKeepsTombstone() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try HostPlacementLedger(fileURL: url); let id = UUID()
        _ = try ledger.admit(operationID: id, owner: owner(), intent: intent(), sample: sample(), at: now)
        try ledger.complete(operationID: id, worktreeID: "/project/.worktrees/task", paneID: "pane")
        let restored = try HostPlacementLedger(fileURL: url)
        #expect(try restored.status(operationID: id, owner: owner())?.paneID == "pane")
        try restored.releaseDeletedWorktree("/project/.worktrees/task")
        #expect(try restored.admit(operationID: id, owner: owner(), intent: intent(), sample: nil, at: now).state == .released)
        _ = try restored.admit(operationID: UUID(), owner: owner(), intent: intent("next"), sample: sample(), at: now)
    }

    @Test func rejectsUnknownStaleAndWrongFilesystemWithoutWriting() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try HostPlacementLedger(fileURL: url)
        var stale = sample(); stale.sampledAt = 800
        var wrongPath = sample(); wrongPath.diskPath = "/elsewhere"
        for sample in [nil, stale, wrongPath] {
            #expect(throws: (any Error).self) { try ledger.admit(operationID: UUID(), owner: owner(), intent: intent(), sample: sample, at: now) }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func persistenceFailureDoesNotReserveInMemoryAndCorruptionFailsClosed() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try HostPlacementLedger(fileURL: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try ledger.admit(operationID: UUID(), owner: owner(), intent: intent(), sample: sample(), at: now) }
        #expect(ledger.pendingCount == 0)
        try FileManager.default.removeItem(at: url)
        try Data("{bad".utf8).write(to: url)
        #expect(throws: (any Error).self) { try HostPlacementLedger(fileURL: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{bad")
    }
}
