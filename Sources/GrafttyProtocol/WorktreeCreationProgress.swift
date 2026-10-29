import Foundation

/// A bounded diagnostic record, shared by local rows, paired clients, and CLI status.
/// This observes Git and hooks together. It does not infer which hook is executing.
public struct WorktreeCreationProgress: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable {
        case preparing, git, startingPane, ready, failed, interrupted
    }

    public static let maximumOutputBytes = 32 * 1024
    public var operationID: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var phase: Phase = .preparing
    public var output = ""
    public var outputTruncated = false
    public var error: String?

    public init(operationID: String = UUID().uuidString.lowercased(), startedAt: Date = Date()) {
        self.operationID = operationID
        self.startedAt = startedAt
    }

    public var isPending: Bool { phase == .preparing || phase == .git || phase == .startingPane }

    public func showsInSidebar(at now: Date) -> Bool {
        phase != .ready || now.timeIntervalSince(finishedAt ?? startedAt) < 60
    }

    /// Pending creation occupies the terminal area. A terminal explicitly
    /// opened after failure or interruption takes precedence over diagnostics.
    public func showsInTerminalArea(isRunning: Bool) -> Bool {
        isPending || (phase != .ready && !isRunning)
    }

    public var label: String {
        switch phase {
        case .preparing: "Preparing worktree"
        case .git: "Git and hooks running"
        case .startingPane: "Starting pane"
        case .ready: "Creation complete"
        case .failed: "Creation failed"
        case .interrupted: "Creation interrupted"
        }
    }

    public static let interruptionMessage = "The host restarted before creation finished. Git or hooks may still be running. Pane launch will not resume automatically. Check those processes before reopening this worktree."

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    public mutating func transition(to phase: Phase, error: String? = nil, now: Date = Date()) {
        self.phase = phase
        self.error = error.map(Self.plainText)
        if !isPending { finishedAt = now }
    }

    /// Diagnostics are text, never instructions to a terminal emulator.
    public static func plainText(_ text: String) -> String {
        let withoutOSC = text.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)",
            with: "", options: .regularExpression)
        let withoutCSI = withoutOSC.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]",
            with: "", options: .regularExpression)
        let scalars = withoutCSI.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Used only when loading host persistence, never when decoding a live snapshot.
    public mutating func interruptAfterRestart(now: Date = Date()) {
        guard isPending else { return }
        transition(to: .interrupted, error: Self.interruptionMessage, now: now)
    }
}
