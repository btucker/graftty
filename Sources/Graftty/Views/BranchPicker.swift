import SwiftUI
import GrafttyKit

/// Always-visible branch list with a filter `TextField` on top. The
/// search text is internal state; the parent sees only the typed
/// `selection`. Mounted entries are dimmed and unselectable.
///
/// @spec GIT-5.13, GIT-5.16, GIT-5.17, GIT-5.18
struct BranchPicker: View {
    let entries: [BranchPickerEntry]
    @Binding var selection: BranchPickerEntry?
    let onCommit: () -> Void

    @State private var filter: String = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit { onCommit() }

            List(selection: selectionBinding) {
                ForEach(filteredEntries, id: \.self) { entry in
                    row(for: entry)
                        .tag(Optional(entry))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(maxHeight: 180)
        }
        .onChange(of: filter) { _, _ in
            applyAutoSelect()
        }
        .onAppear {
            filterFocused = true
            // Don't auto-select on appear: GIT-5.19 requires that
            // switching to existing-branch mode doesn't side-effect
            // worktreeName via pickExistingBranch. Auto-select fires
            // when the user types into the filter (GIT-5.17).
        }
    }

    private var filteredEntries: [BranchPickerEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(needle) }
    }

    /// Wraps `selection` to reject taps on mounted rows.
    private var selectionBinding: Binding<BranchPickerEntry?> {
        Binding(
            get: { selection },
            set: { new in
                if let new, new.mountedWorktreePath != nil { return }
                if new != selection { selection = new }
            }
        )
    }

    private func applyAutoSelect() {
        let next = BranchPickerViewModel.autoSelect(
            currentSelection: selection,
            in: filteredEntries
        )
        if next != selection { selection = next }
    }

    @ViewBuilder
    private func row(for entry: BranchPickerEntry) -> some View {
        let mountedPath = entry.mountedWorktreePath
        let mounted = mountedPath != nil
        HStack(spacing: 8) {
            Text(entry.name)
                .font(.callout)
                .strikethrough(mounted)
                .lineLimit(1)
            if let mountedPath {
                Text("in worktree \((mountedPath as NSString).lastPathComponent)")
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
            Text(Self.relativeFormatter.localizedString(for: entry.lastCommitDate, relativeTo: Date()))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .opacity(mounted ? 0.5 : 1)
        .allowsHitTesting(!mounted)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
