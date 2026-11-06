import SwiftUI

/// `↑X[+] ↓Y` divergence summary shared by the Mac and mobile worktree rows,
/// as one concatenated `Text` so both tokens share a text run (native
/// baseline/kerning, no HStack gap) while carrying their own colors. The
/// ahead side shows `↑0+` when there are uncommitted changes so the dirty
/// indicator never disappears; the behind side uses a less-muted foreground. Callers decide when
/// stats are empty enough to omit the gutter.
public struct SidebarDivergenceGutter: View {
    let ahead: Int
    let behind: Int
    let hasUncommittedChanges: Bool
    let aheadColor: Color
    let behindColor: Color

    public init(ahead: Int, behind: Int, hasUncommittedChanges: Bool, aheadColor: Color, behindColor: Color = .primary.opacity(0.75)) {
        self.ahead = ahead
        self.behind = behind
        self.hasUncommittedChanges = hasUncommittedChanges
        self.aheadColor = aheadColor
        self.behindColor = behindColor
    }

    /// Each side's token, or nil when it has nothing to say.
    public static func tokens(ahead: Int, behind: Int, hasUncommittedChanges: Bool) -> (ahead: String?, behind: String?) {
        (ahead > 0 || hasUncommittedChanges ? "↑\(ahead)\(hasUncommittedChanges ? "+" : "")" : nil,
         behind > 0 ? "↓\(behind)" : nil)
    }

    public var body: some View {
        commitsText
            .font(.system(size: 10, design: .monospaced))
    }

    private var commitsText: Text {
        let tokens = Self.tokens(ahead: ahead, behind: behind, hasUncommittedChanges: hasUncommittedChanges)
        let aheadText = tokens.ahead.map { Text($0).foregroundColor(aheadColor) }
        let behindText = tokens.behind.map { Text($0).foregroundColor(behindColor) }
        switch (aheadText, behindText) {
        case let (ahead?, behind?): return ahead + Text(" ") + behind
        case let (ahead?, nil): return ahead
        case let (nil, behind?): return behind
        case (nil, nil): return Text("")
        }
    }
}
