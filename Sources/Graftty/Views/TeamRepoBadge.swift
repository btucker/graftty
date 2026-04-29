import SwiftUI
import GrafttyKit

/// Small SF-symbol icon shown next to a team-enabled repo's disclosure header.
/// Implements TEAM-6.1.
struct TeamRepoBadge: View {
    let repoPath: String

    var body: some View {
        Image(systemName: "person.2.fill")
            .foregroundStyle(accentColor)
            .help("Agent team")
    }

    /// Deterministic accent color derived from the repo path (stable across launches).
    /// `String.hashValue` is NOT stable across launches; uses a djb2-style hash instead.
    var accentColor: Color {
        let bytes = Array(repoPath.utf8)
        var sum: UInt32 = 5381
        for b in bytes { sum = sum &* 33 &+ UInt32(b) }
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .indigo]
        return palette[Int(sum) % palette.count]
    }
}
