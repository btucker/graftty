import GrafttyProtocol

struct ModelClient {
    let id: DisplayClientID
    let kind: DisplayClientKind
    let role: DisplayClientRole
}

enum Op {
    case attach(ModelClient, visible: Bool, grid: DisplayGrid)
    case detach(DisplayClientID)
    case takeControl(DisplayClientID, grid: DisplayGrid)
    case release(DisplayClientID)
    case ownerResize(DisplayClientID, believedEpoch: UInt64, grid: DisplayGrid)
    case setVisible(DisplayClientID, Bool)
    case hello(DisplayClientID)
}

struct TaggedSnapshot {
    let snapshot: DisplayOwnershipSnapshot
    let emissionSeq: UInt64
}

struct Delivery {
    let target: DisplayClientID
    let snapshot: DisplayOwnershipSnapshot
    let connectionSeq: Int
    let emissionSeq: UInt64
}

struct DeferredWork {
    let id: Int
    let work: () -> Void
}

enum Event {
    case op(Op)
    case deliver(Delivery)
    case deferred(DeferredWork)
}
