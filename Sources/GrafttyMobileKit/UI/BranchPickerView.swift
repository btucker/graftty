#if canImport(UIKit)
import SwiftUI

struct BranchPickerView: View {
    let entries: [BranchPickerEntry]
    let onSelect: (BranchPickerEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter: String = ""

    var body: some View {
        List {
            ForEach(filtered, id: \.name) { entry in
                row(for: entry)
            }
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: "Filter branches")
        .navigationTitle("Pick branch")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filtered: [BranchPickerEntry] {
        guard !filter.isEmpty else { return entries }
        let needle = filter.lowercased()
        return entries.filter { $0.name.lowercased().contains(needle) }
    }

    @ViewBuilder
    private func row(for entry: BranchPickerEntry) -> some View {
        let mounted = entry.mountedWorktreePath != nil
        Button {
            guard !mounted else { return }
            onSelect(entry)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.name)
                        .strikethrough(mounted)
                    Spacer()
                    Text(relativeDate(entry.lastCommitDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if mounted, let path = entry.mountedWorktreePath {
                    Text("in worktree \((path as NSString).lastPathComponent)")
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.secondary)
                } else if let pr = entry.pr {
                    Text("#\(pr.number) · \(pr.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .disabled(mounted)
        .opacity(mounted ? 0.5 : 1)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
