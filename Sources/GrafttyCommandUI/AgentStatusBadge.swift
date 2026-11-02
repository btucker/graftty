import SwiftUI
import GrafttyProtocol

/// Assignment state and this viewer's connection are independent indicators.
public struct AgentStatusBadge: View {
    private let status: AgentAssignmentStatus
    private let failure: String?
    private let disconnected: Bool
    private let isBusy: Bool?
    private let placement: Placement

    /// AGENT-2.8: sidebar rows defer to the agent's own title spinner.
    public enum Placement: Sendable { case tab, sidebarRow }

    /// `isBusy` is the pane's turn activity from provider hooks. A running
    /// assignment whose turn has stopped is idle, not spinning (AGENT-2.7).
    /// Nil means activity is unknown and keeps the running spinner.
    public init(status: String, needsInput: Bool = false, failure: String? = nil, disconnected: Bool = false,
                processObservation: AgentProcessObservation? = nil, isBusy: Bool? = nil, placement: Placement = .tab) {
        self.status = AgentAssignmentStatus(status: status, needsInput: needsInput, processObservation: processObservation)
        self.failure = failure
        self.disconnected = disconnected
        self.isBusy = isBusy
        self.placement = placement
    }

    /// Whether the agent is working: running, not failed, and not idle.
    public static func spins(status: AgentAssignmentStatus, failure: String?, isBusy: Bool?) -> Bool {
        status == .running && failure == nil && isBusy != false
    }

    /// Whether this placement draws the working spinner.
    public static func showsSpinner(status: AgentAssignmentStatus, failure: String?, isBusy: Bool?, placement: Placement) -> Bool {
        placement == .tab && spins(status: status, failure: failure, isBusy: isBusy)
    }

    private var label: String {
        status == .running && isBusy == false ? "Idle" : status.label
    }

    public var body: some View {
        Group {
            if Self.spins(status: status, failure: failure, isBusy: isBusy) {
                if Self.showsSpinner(status: status, failure: failure, isBusy: isBusy, placement: placement) {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                }
            } else if status == .running && failure == nil {
                Label("Idle", systemImage: "circle").labelStyle(.iconOnly)
            } else {
                Label(status.label, systemImage: failure == nil ? status.systemImage : "exclamationmark.triangle")
                    .labelStyle(.iconOnly)
            }
        }
            .foregroundStyle(status == .failed || status == .waiting || failure != nil ? Color.orange : Color.secondary)
            .help(failure.map { "\(status.label): \($0)" } ?? label)
            .accessibilityLabel(failure.map { "\(status.label): \($0)" } ?? label)
        if disconnected {
            Label("Disconnected", systemImage: "wifi.exclamationmark")
                .labelStyle(.iconOnly).foregroundStyle(.secondary).help("Terminal disconnected")
        }
    }
}
