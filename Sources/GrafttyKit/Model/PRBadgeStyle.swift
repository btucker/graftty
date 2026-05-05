import Foundation

/// Decides what color/animation tone the sidebar `#<number>` badge
/// should use, given a worktree's PR state, CI verdict, and
/// mergeable state.
///
/// Lives in `GrafttyKit` (no SwiftUI dependency) so the decision is
/// unit-testable without touching the UI layer; the `Graftty` view
/// maps the returned `Tone` to a concrete `Color` and applies the
/// pulse modifier when `tone.pulses` is true.
///
/// Priority is most-actionable first: merged > CI failure > CI
/// pending > merge conflict > open. CI signals win over a conflict
/// because they're tighter feedback on the user's current change;
/// once CI is clean, the conflict tone surfaces and tells the user
/// to rebase.
///
/// @spec PR-8.20
public enum PRBadgeStyle {
    public enum Tone: Sendable, Equatable {
        case open
        case merged
        case ciFailure
        case ciPending
        case conflicting

        public var pulses: Bool { self == .ciPending }
    }

    public static func tone(
        state: PRInfo.State,
        checks: PRInfo.Checks,
        mergeable: PRInfo.Mergeable = .unknown
    ) -> Tone {
        switch state {
        case .merged:
            return .merged
        case .open:
            switch checks {
            case .failure: return .ciFailure
            case .pending: return .ciPending
            case .success, .none:
                return mergeable == .conflicting ? .conflicting : .open
            }
        }
    }
}
