import SwiftUI
import GrafttyKit

/// One transcript-grid row used for both chat and system events.
/// 2-column layout: 60pt timestamp gutter (right-aligned, dim,
/// tabular-nums) + content (header line + body). Header is
/// suppressed when `isContinuation` is true.
struct TranscriptRow: View {
    let row: ActivityFeedRow
    let isContinuation: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            timestampView
            contentView
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var timestampView: some View {
        Text(timestampString)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 60, alignment: .trailing)
            .opacity(isContinuation ? 0 : 1)
    }

    @ViewBuilder
    private var contentView: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !isContinuation {
                headerLine
            }
            bodyLine
        }
    }

    @ViewBuilder
    private var headerLine: some View {
        switch row {
        case let .chat(worktree, recipient, _, _, isUrgent):
            HStack(spacing: 6) {
                Text(worktree).fontWeight(.semibold)
                if let recipient {
                    Text("→ \(recipient)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if isUrgent {
                    Spacer(minLength: 0)
                    Text("URGENT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                        .tracking(0.5)
                }
            }
        case let .system(worktree, _, _, _):
            Text(worktree).fontWeight(.semibold)
        case .memberJoined, .memberLeft, .dayDivider:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bodyLine: some View {
        switch row {
        case let .chat(_, _, body, _, _):
            Text(body)
                .fixedSize(horizontal: false, vertical: true)
        case let .system(_, iconName, body, _):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, alignment: .center)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .memberJoined, .memberLeft, .dayDivider:
            EmptyView()
        }
    }

    private var timestampString: String {
        let date: Date
        switch row {
        case let .chat(_, _, _, ts, _),
             let .system(_, _, _, ts):
            date = ts
        case .memberJoined, .memberLeft, .dayDivider:
            return ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
