import GrafttyProtocol
import SwiftUI

/// The question waiting for the user, at the end of the Context scroll.
struct WorktreeContextAsk: View {
    let context: SidebarWorktreeContext
    let secondary: Color

    var body: some View {
        if let question = context.question {
            VStack(alignment: .leading, spacing: 8) {
                Text("Waiting for you").font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
                Text(question).font(.title3).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("worktree.context.ask")
        }
    }
}
