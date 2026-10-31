import GrafttyProtocol
import SwiftUI

/// Both clients render semantic input without knowing which harness delivered it.
struct HarnessTimelineContent: View {
    let presentation: HarnessTimelinePresentation
    let secondary: Color
    var wasTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(presentation.items.enumerated()), id: \.offset) { index, item in
                if [.command, .context].contains(presentation.kind), index > 0 {
                    DisclosureGroup(item.label.isEmpty ? "Output" : item.label) {
                        Text(item.value).font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption).foregroundStyle(secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if !item.label.isEmpty {
                            Text(item.label).font(.caption).foregroundStyle(secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(item.value)
                            .font(presentation.kind == .command ? .callout.monospaced() : .callout)
                            .fontWeight(presentation.kind == .questionReply ? .medium : .regular)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if wasTruncated {
                Text("Message shortened").font(.caption2).foregroundStyle(secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("worktree.context.history.\(presentation.kind.rawValue)")
    }
}
