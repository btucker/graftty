import Foundation

/// Decides what color/animation tone the sidebar `#<number>` badge
/// should use, given a worktree's PR state and CI check verdict.
///
/// Lives in `GrafttyKit` (no SwiftUI dependency) so the decision is
/// unit-testable without touching the UI layer; the `Graftty` view
/// maps the returned `Tone` to a concrete `Color` and applies the
/// pulse modifier when `tone.pulses` is true. Mirrors the pattern
/// used by `WorktreeRowIcon`.
public enum PRBadgeStyle {
    public enum Tone: Sendable, Equatable {
        case open
        case merged
        case ciFailure
        case ciPending

        public var pulses: Bool { self == .ciPending }
    }

    public static func tone(state: PRInfo.State, checks: PRInfo.Checks) -> Tone {
        switch state {
        case .merged:
            return .merged
        case .open:
            switch checks {
            case .failure: return .ciFailure
            case .pending: return .ciPending
            case .success, .none: return .open
            }
        }
    }
}
