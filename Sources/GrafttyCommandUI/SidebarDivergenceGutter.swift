import SwiftUI

/// `↑X[+] ↓Y` divergence summary shared by the Mac and mobile worktree rows,
/// as one concatenated `Text` so both tokens share a text run (native
/// baseline/kerning, no HStack gap) while carrying their own colors. The
/// ahead side shows `↑0+` when there are uncommitted changes so the dirty
/// indicator never disappears; the behind side is red. Callers decide when
/// stats are empty enough to omit the gutter.
public struct SidebarDivergenceGutter: View {
    let ahead: Int
    let behind: Int
    let hasUncommittedChanges: Bool
    let aheadColor: Color

    public init(ahead: Int, behind: Int, hasUncommittedChanges: Bool, aheadColor: Color) {
        self.ahead = ahead
        self.behind = behind
        self.hasUncommittedChanges = hasUncommittedChanges
        self.aheadColor = aheadColor
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
            .foregroundColor(.red)
        switch (aheadShown, behindShown) {
        case (true, true): return aheadText + Text(" ") + behindText
        case (true, false): return aheadText
        case (false, true): return behindText
        case (false, false): return Text("")
        }
    }
}
