public enum RemoteHostConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case failed(reason: String)
    case closed

    /// `true` for the two terminal values. `RemoteHostConnection.setState`
    /// refuses any further transition once this is true — see its doc
    /// comment. Public because connection lifecycle coordinators live in
    /// platform UI modules while this state machine is shared by macOS
    /// and iOS. Keeping the predicate here avoids duplicating the
    /// terminal-case switch across consumers if a state is added later.
    public var isTerminal: Bool {
        switch self {
        case .failed, .closed: return true
        case .idle, .connecting, .connected: return false
        }
    }
}

