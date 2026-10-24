import Foundation
import GrafttyProtocol

/// An evacuation operation, not a Git checkpoint or a receipt of saved work.
public struct HostDrainRecord: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let notice: HostInterruptionNotice
    public let startedAt: Date
    public var deadline: Date
    public let placements: [HostPlacementRecord]
}

/// The host state lease guarantees one runtime per directory. Main-actor isolation
/// serializes admission; the durable intent is written before any asynchronous work.
@MainActor
public final class HostPlacementLedger {
    private struct Document: Codable {
        var version = 1
        var records: [HostPlacementRecord] = []
        var drain: HostDrainRecord?
    }
    private let file: JSONFileStore<Document>
    private var document: Document
    public var pendingCount: Int { document.records.filter { $0.state == .preparing || $0.state == .outcomeUnknown }.count }
    public var drain: HostDrainRecord? { document.drain }
    public var retainedRecords: [HostPlacementRecord] { document.records.filter { $0.state != .released } }

    public init(fileURL: URL) throws {
        file = JSONFileStore(fileURL: fileURL, outputFormatting: [.sortedKeys], posixPermissions: 0o600)
        var loaded = try file.load() ?? Document()
        guard loaded.version == 1, loaded.records.count <= 10000,
              Set(loaded.records.map(\.operationID)).count == loaded.records.count else {
            throw HostRuntimeError.invalid("Invalid or unsupported placement ledger")
        }
        for index in loaded.records.indices {
            try Self.validate(loaded.records[index].intent)
            guard loaded.records[index].admittedAt.timeIntervalSince1970.isFinite else {
                throw HostRuntimeError.invalid("Invalid placement timestamp")
            }
            if loaded.records[index].state == .preparing {
                let record = loaded.records[index]
                loaded.records[index] = Self.replacing(record, state: .outcomeUnknown,
                    message: "Host restarted during creation. Inspect the worktree before resolving this operation.")
            }
        }
        document = loaded
        if let drain = loaded.drain {
            try drain.notice.validate()
            guard drain.startedAt.timeIntervalSince1970.isFinite, drain.deadline.timeIntervalSince1970.isFinite,
                  drain.deadline <= drain.notice.deadline else { throw HostRuntimeError.invalid("Invalid drain state") }
        }
        // Persist recovery before serving any new admission. Never discard unreadable state.
        if loaded.records.contains(where: { $0.state == .outcomeUnknown }) { try file.save(loaded) }
    }

    @discardableResult
    public func beginDrain(_ notice: HostInterruptionNotice, at now: Date = Date()) throws -> HostDrainRecord {
        try notice.validate()
        guard now.timeIntervalSince1970.isFinite else { throw HostRuntimeError.invalid("Invalid drain timestamp") }
        var drain = document.drain ?? HostDrainRecord(operationID: UUID(), notice: notice, startedAt: now,
            deadline: notice.deadline, placements: document.records.filter { $0.state != .released })
        drain.deadline = min(drain.deadline, notice.deadline)
        // Refuse new work even if the disk cannot persist the interruption.
        // Repeated notices retry the same write without creating a new operation.
        document.drain = drain
        try file.save(document)
        return drain
    }

    public func status(operationID: UUID, owner: RemoteMacConnectionSummary.ID) throws -> HostPlacementRecord? {
        guard let record = document.records.first(where: { $0.operationID == operationID }) else { return nil }
        guard record.owner == owner else { throw HostRuntimeError.invalid("Placement belongs to another authenticated peer") }
        return record
    }

    public func admit(operationID: UUID, owner: RemoteMacConnectionSummary.ID, intent: HostPlacementIntent,
                      sample: HostResourceSnapshot?, filesystemPath: String? = nil, at now: Date = Date()) throws -> HostPlacementRecord {
        if let prior = try status(operationID: operationID, owner: owner) {
            guard prior.intent == intent else { throw HostRuntimeError.invalid("Placement operation arguments cannot change on retry") }
            return prior
        }
        guard document.drain == nil else { throw HostRuntimeError.busy("Host is draining for interruption") }
        try Self.validate(intent)
        guard document.records.count < 10000 else { throw HostRuntimeError.busy("Placement history limit reached") }
        let claims = document.records.filter { $0.state != .released }
        guard !claims.contains(where: { $0.intent.worktreePath == intent.worktreePath }) else {
            throw HostRuntimeError.busy("Worktree destination already has a placement")
        }
        guard var sample, sample.diskPath == (filesystemPath ?? intent.repositoryID) else {
            throw HostRuntimeError.busy("Fresh resource measurements for this repository filesystem are required")
        }
        var cpu = intent.demand.cpus
        var memory = intent.demand.memoryBytes
        var disk = intent.demand.diskBytes
        for record in claims {
            cpu += record.intent.demand.cpus
            let mem = memory.addingReportingOverflow(record.intent.demand.memoryBytes)
            // Conservatively charge disk claims across all repositories until volumes are tracked.
            let space = disk.addingReportingOverflow(record.intent.demand.diskBytes)
            guard !mem.overflow, !space.overflow else { throw HostRuntimeError.busy("Reserved resources exceed capacity") }
            memory = mem.partialValue; disk = space.partialValue
        }
        // The ledger accounts for these placements explicitly instead of treating the count as unknown.
        sample.pendingPlacements = 0
        let demand = HostPlacementDemand(architecture: intent.demand.architecture, cpus: cpu, memoryBytes: memory, diskBytes: disk)
        let host = RemoteMacConnectionSummary(deviceID: owner.deviceID, fingerprint: owner.fingerprint,
            label: "local admission", lastKnownHost: nil, state: .connected,
            resourceObservation: .init(sample: sample, receivedAt: now.timeIntervalSince1970))
        let plan = try HostPlacementPlanner.plan(hosts: [host], demand: demand, at: now)
        guard plan.selectedHost != nil else {
            throw HostRuntimeError.busy("Host admission rejected: " + plan.rejected.flatMap(\.reasons).joined(separator: ", "))
        }
        let record = HostPlacementRecord(operationID: operationID, owner: owner, intent: intent, admittedAt: now)
        var next = document; next.records.append(record)
        try save(next)
        return record
    }

    public func record(for path: String) -> HostPlacementRecord? {
        document.records.first { $0.intent.worktreePath == path && $0.state != .released }
    }
    public func environment(for path: String) -> PreparedDevContainer? { record(for: path)?.environment }


    public func recordEnvironment(operationID: UUID, environment: PreparedDevContainer) throws {
        try update(operationID) { record in
            guard record.state == .preparing, record.intent.devContainer != nil, environment.workspace == record.intent.worktreePath else {
                throw HostRuntimeError.invalid("Environment does not match the admitted placement")
            }
            return HostPlacementRecord(operationID: record.operationID, owner: record.owner, intent: record.intent,
                admittedAt: record.admittedAt, state: record.state, worktreeID: record.worktreeID, paneID: record.paneID,
                message: record.message, environment: environment)
        }
    }

    public func complete(operationID: UUID, worktreeID: String, paneID: String) throws {
        try update(operationID) { record in
            guard record.state == .preparing, worktreeID == record.intent.worktreePath, !paneID.isEmpty else {
                throw HostRuntimeError.invalid("Invalid placement completion")
            }
            return HostPlacementRecord(operationID: record.operationID, owner: record.owner, intent: record.intent,
                admittedAt: record.admittedAt, state: .created, worktreeID: worktreeID, paneID: paneID, environment: record.environment)
        }
    }

    public func markOutcomeUnknown(operationID: UUID, message: String) throws {
        try update(operationID) { record in
            guard record.state == .preparing else { return record }
            return Self.replacing(record, state: .outcomeUnknown, message: String(message.prefix(2048)))
        }
    }

    public func releaseDeletedWorktree(_ path: String) throws {
        var next = document
        for index in next.records.indices where next.records[index].intent.worktreePath == path && next.records[index].state != .released {
            guard next.records[index].state != .preparing else { throw HostRuntimeError.busy("Placement is still preparing") }
            next.records[index] = Self.replacing(next.records[index], state: .released, message: "Worktree deleted")
        }
        if next.records != document.records { try save(next) }
    }

    public func recordCleanupFailure(operationID: UUID, containerID: String, message: String) throws {
        var next = document
        for index in next.records.indices where next.records[index].state == .released && next.records[index].operationID == operationID {
            next.records[index] = Self.replacing(next.records[index], state: .released,
                message: "Worktree deleted; cleanup of stopped container " + containerID + " remains: " + String(message.prefix(2048)))
        }
        try save(next)
    }

    private func update(_ id: UUID, change: (HostPlacementRecord) throws -> HostPlacementRecord) throws {
        guard let index = document.records.firstIndex(where: { $0.operationID == id }) else { throw HostRuntimeError.notFound("Placement not found") }
        var next = document; next.records[index] = try change(next.records[index]); try save(next)
    }
    private func save(_ next: Document) throws { try file.save(next); document = next }
    private static func replacing(_ record: HostPlacementRecord, state: HostPlacementRecord.State, message: String) -> HostPlacementRecord {
        .init(operationID: record.operationID, owner: record.owner, intent: record.intent, admittedAt: record.admittedAt,
              state: state, worktreeID: record.worktreeID, paneID: record.paneID, message: message, environment: record.environment)
    }
    private static func validate(_ intent: HostPlacementIntent) throws {
        guard intent.repositoryID.hasPrefix("/"), intent.repositoryID.utf8.count <= 4096,
              intent.worktreeName.utf8.count <= 1024, intent.branchName.utf8.count <= 1024,
              intent.repositoryID.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !intent.repositoryID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              WorktreeCreationInput.validationError(worktreeName: intent.worktreeName, branchName: intent.branchName, existing: false, base: nil) == nil else {
            throw HostRuntimeError.invalid("Invalid placement repository, worktree or branch")
        }
        if let configuration = intent.devContainer?.configuration {
            guard !configuration.isEmpty, configuration.utf8.count <= 4096, !configuration.hasPrefix("/"),
                  !configuration.split(separator: "/").contains(".."),
                  !configuration.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw HostRuntimeError.invalid("Dev Container configuration must be a path inside the new worktree")
            }
        }
        if let skills = intent.devContainer?.skills { try RemoteSkillTransferReceiver.validate(skills) }
        if let grants = intent.devContainer?.mcpGrants { try MCPProfileMount.validate(grants, worktree: intent.worktreePath) }
        if let agent = intent.devContainer?.agentRuntime {
            guard TeamHookRuntime(rawValue: agent) != nil, intent.devContainer?.skills?.contains(where: { $0.runtime == agent }) == true else {
                throw HostRuntimeError.invalid("Agent launch requires a matching staged skill revision")
            }
        }
        try HostPlacementPlanner.validate(demand: intent.demand, policy: .init())
    }
}
