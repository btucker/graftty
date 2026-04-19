import SwiftUI
import EspalierKit

/// Sheet for creating a new worktree under a repo. Collects a directory
/// name (used for the worktree path at `<repo>/.worktrees/<name>`) and a
/// branch name that defaults to mirror the worktree name but can be
/// edited independently.
struct AddWorktreeSheet: View {
    let repoDisplayName: String
    /// Called with (worktreeName, branchName) on submit. The caller
    /// performs the git invocation and dismisses the sheet.
    let onSubmit: (String, String) async -> String?
    let onCancel: () -> Void

    @State private var worktreeName: String = ""
    @State private var branchName: String = ""
    /// Tracks whether the branch field is still mirroring the worktree
    /// name. Once the user types something different in the branch field,
    /// we stop auto-syncing so their edit sticks.
    @State private var branchMirrorsWorktree: Bool = true
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    @FocusState private var worktreeFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Worktree to \(repoDisplayName)")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Worktree name:")
                        .foregroundStyle(.secondary)
                    TextField("feature-xyz", text: $worktreeName)
                        .textFieldStyle(.roundedBorder)
                        .focused($worktreeFieldFocused)
                        .onChange(of: worktreeName) { _, new in
                            let sanitized = WorktreeNameSanitizer.sanitize(new)
                            if sanitized != new {
                                worktreeName = sanitized
                                return
                            }
                            if branchMirrorsWorktree {
                                branchName = sanitized
                            }
                        }
                }
                GridRow {
                    Text("Branch:")
                        .foregroundStyle(.secondary)
                    TextField("feature-xyz", text: $branchName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: branchName) { _, new in
                            let sanitized = WorktreeNameSanitizer.sanitize(new)
                            if sanitized != new {
                                branchName = sanitized
                                return
                            }
                            // Once the user types a branch name that differs
                            // from the worktree name, stop auto-syncing so
                            // their edit persists.
                            if sanitized != worktreeName {
                                branchMirrorsWorktree = false
                            }
                        }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { worktreeFieldFocused = true }
    }

    /// Characters stripped from either end when finalizing submission. We
    /// don't trim these as-you-type (it would swallow the separator between
    /// words) but a leading or trailing '-' or '.' in the final name is
    /// never what the user wants — and git rejects a leading '.' anyway.
    private static let submitTrimSet: CharacterSet = {
        var set = CharacterSet.whitespaces
        set.insert(charactersIn: "-.")
        return set
    }()

    private var canSubmit: Bool {
        let wt = worktreeName.trimmingCharacters(in: Self.submitTrimSet)
        let br = branchName.trimmingCharacters(in: Self.submitTrimSet)
        return !wt.isEmpty && !br.isEmpty
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let wt = worktreeName.trimmingCharacters(in: Self.submitTrimSet)
        let br = branchName.trimmingCharacters(in: Self.submitTrimSet)
        if let err = await onSubmit(wt, br) {
            errorMessage = err
        }
    }
}
