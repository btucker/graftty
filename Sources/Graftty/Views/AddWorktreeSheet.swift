import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol

/// Sheet for creating a new worktree under a repo. Collects a directory
/// name (used for the worktree path at `<repo>/.worktrees/<name>`) and a
/// branch selection that is either a fresh branch name (mirrors the
/// worktree name until edited independently) or an existing branch
/// picked from the BranchComboBox.
struct AddWorktreeSheet: View {
    enum BranchMode: Hashable { case newBranch, existing }

    let repoDisplayName: String
    let initialWorktreeName: String
    let branchEntries: [BranchPickerEntry]
    /// Called with (worktreeName, branchSelection) on submit. The caller
    /// performs the git invocation and dismisses the sheet.
    let onSubmit: (String, BranchSelection) async -> String?
    let onCancel: () -> Void

    @State private var worktreeName: String
    @State private var branchName: String
    @State private var branchMode: BranchMode = .newBranch
    /// Tracks whether the branch field is still mirroring the worktree
    /// name. Once the user types something different in the branch field
    /// (in `.newBranch` mode), we stop auto-syncing so their edit sticks.
    @State private var branchMirrorsWorktree: Bool = true
    /// @spec GIT-5.15: When the user selects a branch from the existing-branch picker, the application shall auto-fill the worktree name with the branch name unless the user has already edited the field.
    ///
    /// Tracks whether the worktree field still mirrors the branch
    /// selection (in `.existing` mode). Once the user types a different
    /// worktree name, we stop auto-syncing.
    @State private var worktreeMirrorsBranch: Bool = true
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var selectedExistingSource: BranchSelection.ExistingSource = .local

    @FocusState private var worktreeFieldFocused: Bool

    init(
        repoDisplayName: String,
        initialWorktreeName: String = "",
        branchEntries: [BranchPickerEntry] = [],
        onSubmit: @escaping (String, BranchSelection) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.repoDisplayName = repoDisplayName
        self.initialWorktreeName = initialWorktreeName
        self.branchEntries = branchEntries
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _worktreeName = State(initialValue: initialWorktreeName)
        _branchName = State(initialValue: initialWorktreeName)
    }

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
                            if branchMode == .newBranch && branchMirrorsWorktree {
                                branchName = sanitized
                            }
                            if branchMode == .existing && sanitized != branchName {
                                worktreeMirrorsBranch = false
                            }
                        }
                }
                GridRow {
                    Text("Branch:")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $branchMode) {
                            Text("New branch").tag(BranchMode.newBranch)
                            Text("Existing branch").tag(BranchMode.existing)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if branchMode == .newBranch {
                            TextField("feature-xyz", text: $branchName)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: branchName) { _, new in
                                    let sanitized = WorktreeNameSanitizer.sanitize(new)
                                    if sanitized != new {
                                        branchName = sanitized
                                        return
                                    }
                                    // Once the user types a branch name that
                                    // differs from the worktree name, stop
                                    // auto-syncing so their edit persists.
                                    if sanitized != worktreeName {
                                        branchMirrorsWorktree = false
                                    }
                                }
                        } else {
                            BranchComboBox(
                                text: $branchName,
                                entries: branchEntries
                            ) { entry in
                                branchName = entry.name
                                selectedExistingSource = entry.source
                                if worktreeMirrorsBranch {
                                    worktreeName = entry.name
                                }
                            }
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
        .frame(width: 460)
        .onAppear {
            worktreeFieldFocused = true
            if !initialWorktreeName.isEmpty {
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !WorktreeNameSanitizer.trimForSubmit(worktreeName).isEmpty
            && !WorktreeNameSanitizer.trimForSubmit(branchName).isEmpty
    }

    private var selectedSelection: BranchSelection {
        let trimmed = WorktreeNameSanitizer.trimForSubmit(branchName)
        switch branchMode {
        case .newBranch:
            return .createNew(name: trimmed)
        case .existing:
            return .useExisting(name: trimmed, source: selectedExistingSource)
        }
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let wt = WorktreeNameSanitizer.trimForSubmit(worktreeName)
        if let err = await onSubmit(wt, selectedSelection) {
            errorMessage = err
        }
    }
}
