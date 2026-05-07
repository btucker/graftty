import SwiftUI

/// Centered horizontal-rule row used for member-joined / member-left
/// events. Distinct visual class from the timestamp-gutter grid: no
/// timestamp shown, the actor's name appears inline with the marker
/// text between two hairline rules.
struct CenteredMarkerRow: View {
    enum Kind: Equatable {
        case joined(worktree: String)
        case left(worktree: String)

        var actor: String {
            switch self {
            case .joined(let worktree), .left(let worktree):
                return worktree
            }
        }

        var trailingText: String {
            switch self {
            case .joined: return "joined the team"
            case .left: return "left the team"
            }
        }
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: 12) {
            Divider()
            HStack(spacing: 4) {
                Text(kind.actor).foregroundStyle(.secondary)
                Text(kind.trailingText).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .fixedSize()
            Divider()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}
