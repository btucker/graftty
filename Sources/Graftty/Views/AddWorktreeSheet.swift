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
    let defaultBranchStatus: WebServer.RepoInfo.DefaultBranchStatus?
    let onPullDefaultBranch: () async -> String?
    let onSubmit: (String, BranchSelection, WorktreeAgentConfiguration) async -> String?
    let onCancel: () -> Void

    @State private var controller: AddWorktreeFormController
    @State private var isSubmitting: Bool = false
    @State private var isPullingDefaultBranch: Bool = false
    @State private var defaultBranchOfferDismissed: Bool = false
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?

    @FocusState private var worktreeFieldFocused: Bool
    @FocusState private var taskFieldFocused: Bool

    init(
        repoDisplayName: String,
        initialWorktreeName: String = "",
        branchEntries: [BranchPickerEntry] = [],
        defaultBranchStatus: WebServer.RepoInfo.DefaultBranchStatus? = nil,
        onPullDefaultBranch: @escaping () async -> String? = { nil },
        onSubmit: @escaping (String, BranchSelection, WorktreeAgentConfiguration) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.repoDisplayName = repoDisplayName
        self.initialWorktreeName = initialWorktreeName
        self.branchEntries = branchEntries
        self.defaultBranchStatus = defaultBranchStatus
        self.onPullDefaultBranch = onPullDefaultBranch
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
                    TextField("Automatic if blank", text: $controller.worktreeName)
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
                                onCommit: { startSubmission() }
                            )
                        }
                    }
                }
            }
            .disabled(isSubmitting)

            Picker("Agent", selection: $controller.agent.provider) {
                Text("Default agent").tag(String?.none)
                Text("Codex").tag(Optional("codex"))
                Text("Claude").tag(Optional("claude"))
            }
            .disabled(isSubmitting)
            VStack(alignment: .leading, spacing: 6) {
                Text("What do you want to do?").foregroundStyle(.secondary)
                TextEditor(text: $controller.agent.taskDescription)
                    .focused($taskFieldFocused)
                    .font(.body)
                    .frame(height: 100)
                    .padding(4)
                    .border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("What do you want to do?")
                Text("Optional. Sent as the agent's first message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(isSubmitting)

            if shouldOfferDefaultBranchPull, let status = defaultBranchStatus {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(status.branchName) is \(status.behindCount) \(status.behindCount == 1 ? "commit" : "commits") behind \(status.remoteRef).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Pull First") {
                            Task { await pullDefaultBranch() }
                        }
                        .disabled(isPullingDefaultBranch || isSubmitting)
                        Button("Create Anyway") {
                            defaultBranchOfferDismissed = true
                            startSubmission()
                        }
                        .disabled(isPullingDefaultBranch || isSubmitting || !controller.canSubmit)
                    }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    submissionTask?.cancel()
                    onCancel()
                }
                    .keyboardShortcut(.cancelAction)
                Button {
                    startSubmission()
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.return, modifiers: taskFieldFocused ? .command : [])
                .disabled(!controller.canSubmit || isSubmitting || isPullingDefaultBranch || shouldOfferDefaultBranchPull)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { submissionTask?.cancel() }
        .onAppear {
            worktreeFieldFocused = true
            if !initialWorktreeName.isEmpty {
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
    }

    private func startSubmission() {
        guard controller.canSubmit, !isSubmitting, !isPullingDefaultBranch, !shouldOfferDefaultBranchPull else { return }
        errorMessage = nil
        isSubmitting = true
        submissionTask = Task { @MainActor in
            defer { isSubmitting = false }
            do {
                guard let submission = try await controller.submission(repositoryName: repoDisplayName) else { return }
                try Task.checkCancellation()
                if let err = await onSubmit(submission.worktree, submission.branch, submission.agent) {
                    errorMessage = err
                }
            } catch is CancellationError {
                // Closing the sheet during generation must not create a worktree.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var shouldOfferDefaultBranchPull: Bool {
        guard controller.branchMode == .newBranch,
              let defaultBranchStatus,
              defaultBranchStatus.behindCount > 0,
              !defaultBranchOfferDismissed else {
            return false
        }
        return true
    }

    private func pullDefaultBranch() async {
        errorMessage = nil
        isPullingDefaultBranch = true
        defer { isPullingDefaultBranch = false }
        if let err = await onPullDefaultBranch() {
            errorMessage = err
        } else {
            defaultBranchOfferDismissed = true
        }
    }
}
