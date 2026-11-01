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

    public var body: some View {
        commitsText
            .font(.system(size: 10, design: .monospaced))
    }

    private var commitsText: Text {
        let aheadShown = ahead > 0 || hasUncommittedChanges
        let behindShown = behind > 0
        let aheadText = Text("↑\(ahead)\(hasUncommittedChanges ? "+" : "")")
            .foregroundColor(aheadColor)
        let behindText = Text("↓\(behind)")
            .foregroundColor(behindColor)
        switch (aheadShown, behindShown) {
        case (true, true): return aheadText + Text(" ") + behindText
        case (true, false): return aheadText
        case (false, true): return behindText
        case (false, false): return Text("")
        }
    }
}
