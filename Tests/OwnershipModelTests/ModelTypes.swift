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

struct Delivery {
    let target: DisplayClientID
    let snapshot: DisplayOwnershipSnapshot
    let connectionSeq: Int
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
