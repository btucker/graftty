import GrafttyProtocol
import SwiftUI

/// Results remain reviewable without presenting an answer field.
struct WorktreeContextNotices: View {
    let context: SidebarWorktreeContext
    let secondary: Color
    @Environment(\.worktreeContextActions) private var actions
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(context.pending.filter { $0.agentStop?.notice != nil }) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text("For review").font(.caption).foregroundStyle(secondary)
                    Text(item.agentStop?.notice ?? item.title).fixedSize(horizontal: false, vertical: true)
                    if let dismiss = actions?.dismissNotice, let occurrence = item.occurrence {
                        Button("Dismiss") {
                            isSending = true
                            failure = nil
                            Task { @MainActor in
                                failure = await dismiss(context.worktree, occurrence)
                                isSending = false
                            }
                        }
                        .disabled(isSending)
                        .accessibilityIdentifier("worktree.context.notice.dismiss")
                    }
                }
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(secondary) }
        }
        .accessibilityIdentifier("worktree.context.notices")
    }
}
