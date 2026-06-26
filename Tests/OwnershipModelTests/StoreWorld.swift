import GrafttyProtocol
@testable import GrafttyKit

struct ApplyResult {
    var resize: SessionDisplayOwnershipResizeResult?
    var requestedEpoch: UInt64?
}

/// Drives only the real `SessionDisplayOwnershipStore`.
/// Adapter-only ops (`.setVisible`, `.hello`) are no-ops here.
struct StoreWorld {
    let session: String
    let store: SessionDisplayOwnershipStore

    /// Clients currently attached to the store, keyed by ID.
    private var attachedClientInfo: [DisplayClientID: ModelClient] = [:]

    /// The last epoch this world saw after any op, per client.
    /// Used so `randomLegalOp` can produce both correct and stale epochs.
    private var clientEpochs: [DisplayClientID: UInt64] = [:]

    private static let availableGrids: [DisplayGrid] = {
        [80, 120, 220].map { try! DisplayGrid(cols: $0, rows: 24) }
    }()

    init(session: String) {
        self.session = session
        self.store = SessionDisplayOwnershipStore()
    }

    @discardableResult
    mutating func apply(_ op: Op) -> ApplyResult {
        var result = ApplyResult()

        switch op {
        case .attach(let client, let visible, let grid):
            let snapshot = store.attachClient(
                sessionName: session,
                clientID: client.id,
                kind: client.kind,
                role: client.role,
                visible: visible,
                grid: grid
            )
            attachedClientInfo[client.id] = client
            updateEpochs(from: snapshot)

        case .detach(let clientID):
            let snapshot = store.detachClient(sessionName: session, clientID: clientID)
            attachedClientInfo.removeValue(forKey: clientID)
            clientEpochs.removeValue(forKey: clientID)
            updateEpochs(from: snapshot)

        case .takeControl(let clientID, let grid):
            let kind = attachedClientInfo[clientID]?.kind ?? .mac
            let claimResult = store.claimOwner(
                sessionName: session,
                clientID: clientID,
                kind: kind,
                grid: grid
            )
            updateEpochs(from: claimResult.snapshot)

        case .release(let clientID):
            let snapshot = store.releaseOwner(sessionName: session, clientID: clientID)
            updateEpochs(from: snapshot)

        case .ownerResize(let clientID, let believedEpoch, let grid):
            result.requestedEpoch = believedEpoch
            let resizeResult = store.ownerResize(
                sessionName: session,
                clientID: clientID,
                epoch: believedEpoch,
                grid: grid
            )
            result.resize = resizeResult
            updateEpochs(from: resizeResult.snapshot)

        case .setVisible, .hello:
            break  // adapter-only ops; not part of the store API
        }

        return result
    }

    /// Produces a plausible op from `clients`. Ensures at least one client stays attached
    /// so the session record's grid is always set (preventing epoch reset on record deletion).
    mutating func randomLegalOp(clients: [ModelClient], using rng: inout DeterministicRNG) -> Op {
        let grid = Self.availableGrids[rng.int(in: 0..<Self.availableGrids.count)]

        // First op (or after full detach): always attach a visible client so the
        // store auto-assigns an owner and sets a grid, anchoring the epoch baseline.
        guard !attachedClientInfo.isEmpty else {
            return .attach(rng.pick(clients), visible: true, grid: grid)
        }

        // Sort for determinism — Dictionary.keys order is unspecified.
        let attachedIDs = attachedClientInfo.keys.sorted { $0.rawValue < $1.rawValue }
        let id = rng.pick(attachedIDs)

        switch rng.int(in: 0..<5) {
        case 0:
            return .attach(rng.pick(clients), visible: rng.int(in: 0..<2) == 0, grid: grid)
        case 1:
            // Avoid detaching the last client — keeps the record's grid set, preventing epoch reset.
            if attachedClientInfo.count > 1 {
                return .detach(id)
            }
            return .attach(rng.pick(clients), visible: true, grid: grid)
        case 2:
            return .takeControl(id, grid: grid)
        case 3:
            return .release(id)
        default:
            // Occasionally send a stale epoch (0) to exercise the store's rejection gate.
            let epoch = rng.int(in: 0..<4) == 0 ? 0 : (clientEpochs[id] ?? 0)
            return .ownerResize(id, believedEpoch: epoch, grid: grid)
        }
    }

    private mutating func updateEpochs(from snapshot: DisplayOwnershipSnapshot) {
        // Epoch is session-wide; refresh every tracked client's view.
        for id in attachedClientInfo.keys {
            clientEpochs[id] = snapshot.epoch
        }
    }
}
