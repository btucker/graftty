import SwiftUI
import GrafttyProtocol

/// Assignment state and this viewer's connection are independent indicators.
public struct AgentStatusBadge: View {
    private let status: AgentAssignmentStatus
    private let failure: String?
    private let disconnected: Bool

    public init(status: String, needsInput: Bool = false, failure: String? = nil, disconnected: Bool = false, processObservation: AgentProcessObservation? = nil) {
        self.status = AgentAssignmentStatus(status: status, needsInput: needsInput, processObservation: processObservation)
        self.failure = failure
        self.disconnected = disconnected
    }

    public var body: some View {
        Label(status.label, systemImage: failure == nil ? status.systemImage : "exclamationmark.triangle")
            .labelStyle(.iconOnly)
            .foregroundStyle(status == .failed || status == .waiting || failure != nil ? Color.orange : Color.secondary)
            .help(failure.map { "\(status.label): \($0)" } ?? status.label)
            .accessibilityLabel(failure.map { "\(status.label): \($0)" } ?? status.label)
        if disconnected {
            Label("Disconnected", systemImage: "wifi.exclamationmark")
                .labelStyle(.iconOnly).foregroundStyle(.secondary).help("Terminal disconnected")
        }
    }
}
