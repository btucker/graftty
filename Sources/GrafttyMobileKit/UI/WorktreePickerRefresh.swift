#if canImport(UIKit)
import GrafttyProtocol

/// Pure refresh-coordination helper used by `WorktreePickerView`.
/// Extracted so the IOS-4.20 contract — "pull-to-refresh re-fetches in
/// place rather than blanking the list" — is unit-testable without a
/// SwiftUI gesture harness.
public enum WorktreePickerRefresh {

    /// Outcome of a single refresh attempt. The picker view applies
    /// `.replaced(...)` on completion without first transitioning
    /// through a loading state, so the `List` that owns `.refreshable`
    /// stays mounted throughout.
    public enum Transition: Equatable {
        case replaced([WorktreePanes])
        case failed(String)
    }

    /// Drive a refresh against `fetch`. Yields exactly one terminal
    /// transition.
    public static func refresh(
        fetch: () async throws -> [WorktreePanes]
    ) async -> Transition {
        do {
            return .replaced(try await fetch())
        } catch {
            return .failed("\(error)")
        }
    }
}
#endif
