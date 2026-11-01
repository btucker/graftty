/// Assignment status stays separate from the viewer's connection status.
public enum AgentAssignmentStatus: String {
    case starting, running, waiting, closing, closed, failed, interrupted, disconnected, exited
    case awaitingCleanup = "awaiting-cleanup"
    case unknown

    public init(agent: AgentSessionInfo, needsInput: Bool) {
        self.init(status: agent.status, needsInput: needsInput, processObservation: agent.processObservation)
    }

    public init(status: String, needsInput: Bool = false, processObservation: AgentProcessObservation? = nil) {
        self = Self(rawValue: status) ?? .unknown
        if [.running, .starting, .waiting].contains(self) {
            if processObservation == .exited { self = .exited }
            if processObservation == .disconnected { self = .disconnected }
        }
        if needsInput && (self == .running || self == .starting) { self = .waiting }
    }

    public var label: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .waiting: "Waiting for input"
        case .awaitingCleanup: "Finished, awaiting cleanup"
        case .closing: "Closing"
        case .closed: "Closed"
        case .failed: "Failed"
        case .interrupted: "Interrupted, awaiting acknowledgment"
        case .disconnected: "Provider disconnected"
        case .exited: "Provider exited"
        case .unknown: "Status unavailable"
        }
    }

    public var systemImage: String {
        switch self {
        case .starting, .closing: "clock"
        case .running: "circle"
        case .waiting: "hand.raised"
        case .awaitingCleanup: "checkmark.circle"
        case .closed: "checkmark.circle"
        case .failed, .interrupted, .exited: "exclamationmark.triangle"
        case .disconnected: "wifi.exclamationmark"
        case .unknown: "questionmark.circle"
        }
    }
}
