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

        /// A client may own the display only while it is visible, interactive
        /// (non-preview by both role and kind), and still presenting as the
        /// kind the caller is claiming as. This is the single source of truth
        /// for owner eligibility — every claim/restore path routes through it
        /// so the rule can't drift between them.
        func isOwnerEligible(claimingAs kind: DisplayClientKind) -> Bool {
            self.kind == kind
                && self.kind != .preview
                && role != .preview
                && visible
        }
    }

    private struct Record {
        var ownerClientID: DisplayClientID?
        var ownerKind: DisplayClientKind?
        var grid: DisplayGrid?
        var epoch: UInt64 = 0
        var attachedClients: [DisplayClientID: AttachedClient] = [:]
    }

    /// Cancels an observer registration. Cancels automatically on
    /// deinit, so a holder that drops its token (e.g. a `WebServer` being
    /// torn down) is unsubscribed without an explicit call.
    public final class ObserverToken: @unchecked Sendable {
        private let onCancel: () -> Void
        private let lock = NSLock()
        private var cancelled = false

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        public func cancel() {
            lock.lock()
            if cancelled {
                lock.unlock()
                return
            }
            cancelled = true
            lock.unlock()
            onCancel()
        }

        deinit {
            cancel()
        }
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var observers: [UUID: @Sendable (DisplayOwnershipSnapshot) -> Void] = [:]

    public init() {}

    /// Observe every owner-changing mutation. The store is the single source
    /// of truth shared across the Mac host, web, and iOS transports, but only
    /// the web bridge historically broadcast its own mutations — Mac-side
    /// claims/releases mutated the store silently, so web/iOS followers never
    /// learned the Mac took or dropped ownership. Subscribing the web
    /// broadcaster here closes that gap: any mutation, whoever made it, is
    /// pushed to connected clients. The returned token unsubscribes on
    /// `cancel()` / deinit.
    public func addObserver(
        _ observer: @escaping @Sendable (DisplayOwnershipSnapshot) -> Void
    ) -> ObserverToken {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return ObserverToken { [weak self] in
            self?.removeObserver(id)
        }
    }

    private func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    /// Fan a post-mutation snapshot out to observers. MUST be called after the
    /// records lock is released (observers may re-enter store reads); the
    /// mutation methods do this via a `defer` that runs after the unlock
    /// `defer`. Copies the observer list under the lock, then calls outside it.
    private func notifyObservers(_ snapshot: DisplayOwnershipSnapshot) {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        for observe in current {
            observe(snapshot)
        }
    }

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
        record.attachedClients[clientID] = AttachedClient(kind: kind, role: role, visible: visible)

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
        var changedSnapshot: DisplayOwnershipSnapshot?
        defer { changedSnapshot.map(notifyObservers) }
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        guard let attachedClient = record.attachedClients[clientID],
              attachedClient.isOwnerEligible(claimingAs: kind) else {
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
        let result = snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        changedSnapshot = result
        return SessionDisplayOwnershipClaimResult(accepted: true, snapshot: result)
    }

    public func claimOwnerIfOwnerlessOrCurrent(
        sessionName: String,
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        grid: DisplayGrid,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> SessionDisplayOwnershipClaimResult {
        var changedSnapshot: DisplayOwnershipSnapshot?
        defer { changedSnapshot.map(notifyObservers) }
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        guard let attachedClient = record.attachedClients[clientID],
              attachedClient.isOwnerEligible(claimingAs: kind) else {
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
        let result = snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        changedSnapshot = result
        return SessionDisplayOwnershipClaimResult(accepted: true, snapshot: result)
    }

    public func ownerResize(
        sessionName: String,
        clientID: DisplayClientID,
        epoch: UInt64,
        grid: DisplayGrid
    ) -> SessionDisplayOwnershipResizeResult {
        var changedSnapshot: DisplayOwnershipSnapshot?
        defer { changedSnapshot.map(notifyObservers) }
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        let accepted = record.ownerClientID == clientID && record.epoch == epoch
        if accepted {
            record.grid = grid
            records[sessionName] = record
        }

        let result = snapshot(for: sessionName, record: record, fallbackGrid: DisplayGrid.daemonFallback)
        if accepted { changedSnapshot = result }
        return SessionDisplayOwnershipResizeResult(accepted: accepted, snapshot: result)
    }

    public func detachClient(
        sessionName: String,
        clientID: DisplayClientID,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> DisplayOwnershipSnapshot {
        var changedSnapshot: DisplayOwnershipSnapshot?
        defer { changedSnapshot.map(notifyObservers) }
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        record.attachedClients.removeValue(forKey: clientID)

        var ownerCleared = false
        if record.ownerClientID == clientID {
            record.ownerClientID = nil
            record.ownerKind = nil
            record.epoch += 1
            ownerCleared = true
        }

        let result = snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        storeOrRemove(record, for: sessionName)
        if ownerCleared { changedSnapshot = result }
        return result
    }

    public func releaseOwner(
        sessionName: String,
        clientID: DisplayClientID,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> DisplayOwnershipSnapshot {
        var changedSnapshot: DisplayOwnershipSnapshot?
        defer { changedSnapshot.map(notifyObservers) }
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        var ownerCleared = false
        if record.ownerClientID == clientID {
            record.ownerClientID = nil
            record.ownerKind = nil
            record.epoch += 1
            ownerCleared = true
        }

        let result = snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        storeOrRemove(record, for: sessionName)
        if ownerCleared { changedSnapshot = result }
        return result
    }

    public func restoreOwnerAfterFailedClaim(
        sessionName: String,
        failedClientID: DisplayClientID,
        failedKind: DisplayClientKind,
        failedEpoch: UInt64,
        previousOwnerClientID: DisplayClientID?,
        previousOwnerKind: DisplayClientKind?,
        previousGrid: DisplayGrid,
        fallbackGrid: DisplayGrid = .daemonFallback
    ) -> DisplayOwnershipSnapshot {
        var changedSnapshot: DisplayOwnershipSnapshot?
        defer { changedSnapshot.map(notifyObservers) }
        lock.lock()
        defer { lock.unlock() }

        var record = records[sessionName] ?? Record()
        var restored = false
        if record.ownerClientID == failedClientID,
           record.ownerKind == failedKind,
           record.epoch == failedEpoch {
            if let previousOwnerClientID,
               let previousOwnerKind,
               let attachedClient = record.attachedClients[previousOwnerClientID],
               attachedClient.isOwnerEligible(claimingAs: previousOwnerKind) {
                record.ownerClientID = previousOwnerClientID
                record.ownerKind = previousOwnerKind
            } else {
                record.ownerClientID = nil
                record.ownerKind = nil
            }
            record.grid = previousGrid
            record.epoch += 1
            restored = true
        }

        let result = snapshot(for: sessionName, record: record, fallbackGrid: fallbackGrid)
        storeOrRemove(record, for: sessionName)
        if restored { changedSnapshot = result }
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
