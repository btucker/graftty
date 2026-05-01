import GrafttyProtocol

@MainActor
public protocol PanePreviewClienting: AnyObject {
    var sessionName: String { get }
    func start()
    func stop()
}

@MainActor
public final class PanePreviewClientPool<Client: PanePreviewClienting> {
    public typealias Factory = (_ sessionName: String) -> Client

    public private(set) var clients: [String: Client] = [:]

    private let makeClient: Factory

    public init(makeClient: @escaping Factory) {
        self.makeClient = makeClient
    }

    public func update(layout: PaneLayoutNode, maxLivePreviews: Int = .max) {
        let wantedSessionNames = Array(layout.sessionNames.prefix(max(0, maxLivePreviews)))
        let wanted = Set(wantedSessionNames)

        let removed = clients.keys.filter { !wanted.contains($0) }
        for sessionName in removed {
            clients[sessionName]?.stop()
            clients.removeValue(forKey: sessionName)
        }

        for sessionName in wantedSessionNames where clients[sessionName] == nil {
            let client = makeClient(sessionName)
            clients[sessionName] = client
            client.start()
        }
    }

    public func stopAll() {
        for client in clients.values {
            client.stop()
        }
        clients.removeAll()
    }
}

private extension PaneLayoutNode {
    var sessionNames: [String] {
        switch self {
        case let .leaf(sessionName, _):
            return [sessionName]
        case let .split(_, _, left, right):
            return left.sessionNames + right.sessionNames
        }
    }
}

#if canImport(UIKit)
extension SessionClient: PanePreviewClienting {}
#endif
