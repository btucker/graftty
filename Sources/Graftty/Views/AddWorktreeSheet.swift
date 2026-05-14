import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol

/// Sheet for creating a new worktree under a repo. Collects a directory
/// name (used for the worktree path at `<repo>/.worktrees/<name>`) and a
/// branch selection: either a fresh branch name (mirrors the worktree
/// name until edited independently) or an existing branch picked from
/// `BranchPicker`. State lives in `AddWorktreeFormController` so each
/// mode's input survives mode toggles (`GIT-5.19`).
struct AddWorktreeSheet: View {
    typealias BranchMode = AddWorktreeFormController.BranchMode

    let repoDisplayName: String
    let initialWorktreeName: String
    let branchEntries: [BranchPickerEntry]
    let onSubmit: (String, BranchSelection) async -> String?
    let onCancel: () -> Void

    @State private var controller: AddWorktreeFormController
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

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
        _controller = State(initialValue: AddWorktreeFormController(initialWorktreeName: initialWorktreeName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Worktree to \(repoDisplayName)")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Worktree name:")
                        .foregroundStyle(.secondary)
                    TextField("feature-xyz", text: $controller.worktreeName)
                        .textFieldStyle(.roundedBorder)
                        .focused($worktreeFieldFocused)
                        .onChange(of: controller.worktreeName) { _, new in
                            let sanitized = WorktreeNameSanitizer.sanitize(new)
                            if sanitized != new {
                                controller.worktreeName = sanitized
                                return
                            }
                            if controller.branchMode == .newBranch && controller.branchMirrorsWorktree {
                                controller.newBranchName = sanitized
                            }
                            if controller.branchMode == .existing,
                               let selName = controller.existingSelection?.name,
                               sanitized != selName {
                                controller.worktreeMirrorsBranch = false
                            }
                        }
                }
                GridRow {
                    Text("Branch:")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $controller.branchMode) {
                            Text("New branch").tag(BranchMode.newBranch)
                            Text("Existing branch").tag(BranchMode.existing)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if controller.branchMode == .newBranch {
                            TextField("feature-xyz", text: $controller.newBranchName)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: controller.newBranchName) { _, new in
                                    let sanitized = WorktreeNameSanitizer.sanitize(new)
                                    if sanitized != new {
                                        controller.newBranchName = sanitized
                                        return
                                    }
                                    if sanitized != controller.worktreeName {
                                        controller.branchMirrorsWorktree = false
                                    }
                                }
                        } else {
                            BranchPicker(
                                entries: branchEntries,
                                selection: Binding(
                                    get: { controller.existingSelection },
                                    set: { new in
                                        if let new {
                                            controller.pickExistingBranch(new)
                                        } else {
                                            controller.existingSelection = nil
                                        }
                                    }
                                ),
                                onCommit: { Task { await submit() } }
                            )
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
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canSubmit || isSubmitting)
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

    private func submit() async {
        guard let selection = controller.selectedSelection else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let wt = WorktreeNameSanitizer.trimForSubmit(controller.worktreeName)
        if let err = await onSubmit(wt, selection) {
            errorMessage = err
        }
    }
}
