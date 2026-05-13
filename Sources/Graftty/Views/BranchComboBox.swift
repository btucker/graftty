import SwiftUI
import GrafttyKit

/// Combobox: a TextField wrapping a popover that lists matching
/// branches. Selecting a row sets `text` to the branch name and
/// invokes `onSelect`. Mounted rows are disabled and dimmed.
struct BranchComboBox: View {
    @Binding var text: String
    let entries: [BranchPickerEntry]
    let onSelect: (BranchPickerEntry) -> Void

    @State private var showPopover: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        TextField("Pick or type branch name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onChange(of: fieldFocused) { _, focused in
                if focused { showPopover = true }
            }
            .onChange(of: text) { _, _ in
                showPopover = true
            }
            .popover(isPresented: $showPopover, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                popoverList
                    .frame(width: 320)
            }
    }

    private var popoverList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    Text("No branches match")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                } else {
                    ForEach(entries, id: \.name) { entry in
                        row(for: entry)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 240)
    }

    @ViewBuilder
    private func row(for entry: BranchPickerEntry) -> some View {
        let mounted = entry.mountedWorktreePath != nil
        HStack(spacing: 8) {
            Text(entry.name)
                .font(.callout)
                .strikethrough(mounted)
                .lineLimit(1)
            if mounted, let path = entry.mountedWorktreePath {
                Text("in worktree \((path as NSString).lastPathComponent)")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let pr = entry.pr {
                Text("#\(pr.number) · \(pr.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(relativeDate(entry.lastCommitDate))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .opacity(mounted ? 0.5 : 1)
        .background(Color.clear)
        .onTapGesture {
            guard !mounted else { return }
            text = entry.name
            onSelect(entry)
            showPopover = false
        }
        .disabled(mounted)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
