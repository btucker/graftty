import Foundation

/// Controls how often a mounted terminal draws requested frames.
/// Native mailbox processing continues independently of render pacing.
public enum TerminalRenderPace: Equatable, Sendable {
    case full
    /// Coalesce requested frames to at most one per interval in seconds.
    case reduced(interval: TimeInterval)
}
