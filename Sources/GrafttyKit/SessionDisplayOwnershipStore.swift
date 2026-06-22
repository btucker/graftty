import Foundation
import GrafttyProtocol

public struct SessionDisplayOwnershipResizeResult: Sendable, Equatable {
    public let accepted: Bool
    public let snapshot: DisplayOwnershipSnapshot

    public init(accepted: Bool, snapshot: DisplayOwnershipSnapshot) {
        self.accepted = accepted
        self.snapshot = snapshot
    }
}

public struct SessionDisplayOwnershipClaimResult: Sendable, Equatable {
    public let accepted: Bool
    public let snapshot: DisplayOwnershipSnapshot

    public init(accepted: Bool, snapshot: DisplayOwnershipSnapshot) {
        self.accepted = accepted
        self.snapshot = snapshot
    }
}

public final class SessionDisplayOwnershipStore: @unchecked Sendable {
    private struct AttachedClient {
        var kind: DisplayClientKind
        var role: DisplayClientRole
        var visible: Bool
    }

    private struct Record {
        var ownerClientID: DisplayClientID?
        var ownerKind: DisplayClientKind?
        var grid: DisplayGrid?
        var epoch: UInt64 = 0
        var attachedClients: [DisplayClientID: AttachedClient] = [:]
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]

    public init() {}

    public func attachClient(
        sessionName: String,
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        role: DisplayClientRole,
        visible: Bool,
        grid: DisplayGrid
    ) -> DisplayOwnershipSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        let isNewClient = record.attachedClients[clientID] == nil
        record.attachedClients[clientID] = AttachedClient(kind: kind, role: role, visible: visible)

        if isNewClient,
           record.ownerClientID == nil,
           visible,
           role == .interactive,
           kind != .preview {
            record.ownerClientID = clientID
            record.ownerKind = kind
            record.grid = grid
            record.epoch += 1
        }

        records[sessionName] = record
        return snapshot(for: sessionName, record: record, fallbackGrid: grid)
    }

    public func claimOwner(
        sessionName: String,
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        grid: DisplayGrid,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> SessionDisplayOwnershipClaimResult {
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        guard let attachedClient = record.attachedClients[clientID],
              attachedClient.kind == kind,
              attachedClient.kind != .preview,
              attachedClient.role != .preview,
              attachedClient.visible else {
            return SessionDisplayOwnershipClaimResult(
                accepted: false,
                snapshot: snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
            )
        }

        let ownerChanged = record.ownerClientID != clientID || record.ownerKind != kind
        record.ownerClientID = clientID
        record.ownerKind = kind
        record.grid = grid
        if ownerChanged {
            record.epoch += 1
        }

        records[sessionName] = record
        return SessionDisplayOwnershipClaimResult(
            accepted: true,
            snapshot: snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        )
    }

    public func claimOwnerIfOwnerlessOrCurrent(
        sessionName: String,
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        grid: DisplayGrid,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> SessionDisplayOwnershipClaimResult {
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        guard let attachedClient = record.attachedClients[clientID],
              attachedClient.kind == kind,
              attachedClient.kind != .preview,
              attachedClient.role != .preview,
              attachedClient.visible else {
            return SessionDisplayOwnershipClaimResult(
                accepted: false,
                snapshot: snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
            )
        }

        let alreadyCurrentOwner = record.ownerClientID == clientID && record.ownerKind == kind
        guard record.ownerClientID == nil || alreadyCurrentOwner else {
            return SessionDisplayOwnershipClaimResult(
                accepted: false,
                snapshot: snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
            )
        }

        let ownerChanged = !alreadyCurrentOwner
        record.ownerClientID = clientID
        record.ownerKind = kind
        record.grid = grid
        if ownerChanged {
            record.epoch += 1
        }

        records[sessionName] = record
        return SessionDisplayOwnershipClaimResult(
            accepted: true,
            snapshot: snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        )
    }

    public func ownerResize(
        sessionName: String,
        clientID: DisplayClientID,
        epoch: UInt64,
        grid: DisplayGrid
    ) -> SessionDisplayOwnershipResizeResult {
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        let accepted = record.ownerClientID == clientID && record.epoch == epoch
        if accepted {
            record.grid = grid
            records[sessionName] = record
        }

        return SessionDisplayOwnershipResizeResult(
            accepted: accepted,
            snapshot: snapshot(for: sessionName, record: record, fallbackGrid: DisplayGrid.daemonFallback)
        )
    }

    public func detachClient(
        sessionName: String,
        clientID: DisplayClientID,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> DisplayOwnershipSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        record.attachedClients.removeValue(forKey: clientID)

        if record.ownerClientID == clientID {
            record.ownerClientID = nil
            record.ownerKind = nil
            record.epoch += 1
        }

        let result = snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        storeOrRemove(record, for: sessionName)
        return result
    }

    public func releaseOwner(
        sessionName: String,
        clientID: DisplayClientID,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> DisplayOwnershipSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        if record.ownerClientID == clientID {
            record.ownerClientID = nil
            record.ownerKind = nil
            record.epoch += 1
        }

        let result = snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        storeOrRemove(record, for: sessionName)
        return result
    }

    public func snapshot(
        sessionName: String,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> DisplayOwnershipSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let record = records[sessionName] ?? Record()
        return snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
    }

    private func snapshot(
        for sessionName: String,
        record: Record,
        fallbackGrid: DisplayGrid
    ) -> DisplayOwnershipSnapshot {
        try! DisplayOwnershipSnapshot(
            sessionName: sessionName,
            ownerClientID: record.ownerClientID,
            ownerKind: record.ownerKind,
            grid: record.grid ?? fallbackGrid,
            epoch: record.epoch
        )
    }

    private func storeOrRemove(_ record: Record, for sessionName: String) {
        if record.ownerClientID == nil, record.grid == nil, record.attachedClients.isEmpty {
            records.removeValue(forKey: sessionName)
        } else {
            records[sessionName] = record
        }
    }
}
