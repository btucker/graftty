#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// @spec REMOTE-13.10: When GrafttyMobile creates a worktree while the
/// connected Mac exposes repositories from multiple Macs, the Add Worktree
/// sheet shall require an explicit target Mac selection before repository
/// selection and creation.
public struct AddWorktreeSheetView: View {

    public let host: Host
    public let onCreated: (CreateWorktreeClient.Response) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reposState: ReposState = .loading
    @State private var selectedTargetID: String?
    @State private var selectedRepoPath: String?
    @State private var worktreeName: String = ""
    @State private var branchName: String = ""
    /// Once the user types a branch that differs from the worktree name,
    /// stop auto-syncing so their edit sticks.
    @State private var branchMirrorsWorktree: Bool = true
    @State private var branchMode: BranchMode = .newBranch
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    enum BranchMode { case newBranch, existing }

    private struct TargetMac: Identifiable {
        let id: String
        let label: String
    }

    public init(
        host: Host,
        onCreated: @escaping (CreateWorktreeClient.Response) -> Void
    ) {
        self.host = host
        self.onCreated = onCreated
    }

    public static func shouldSubmitOnReturn(canSubmit: Bool, isSubmitting: Bool) -> Bool {
        canSubmit && !isSubmitting
    }

    private enum ReposState {
        case loading
        case loaded([ReposFetcher.RepoInfo])
        case error(String)
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch reposState {
                case .loading:
                    ProgressView().padding()
                case .error(let msg):
                    ContentUnavailableView {
                        Label("Couldn't load repositories", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(msg)
                    } actions: {
                        Button("Retry") { Task { await loadRepos() } }
                            .buttonStyle(.borderedProminent)
                    }
                case .loaded(let repos) where repos.isEmpty:
                    ContentUnavailableView(
                        "No repositories tracked",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Open a repository in Graftty on the Mac first.")
                    )
                case .loaded(let repos):
                    form(repos: repos)
                }
            }
            .disabled(isSubmitting)
            .navigationTitle("Add Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create") { Task { await submit() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSubmit)
                    }
                }
            }
            .task { await loadRepos() }
        }
    }

    @ViewBuilder
    private func form(repos: [ReposFetcher.RepoInfo]) -> some View {
        let targets = targetMacs(in: repos)
        let visibleRepos = repositories(on: selectedTargetID, from: repos)
        Form {
            if targets.count > 1 {
                Section("Target Mac") {
                    Picker("Mac", selection: $selectedTargetID) {
                        ForEach(targets) { target in
                            Text(target.label).tag(Optional(target.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if visibleRepos.count > 1 {
                Section("Repository") {
                    Picker("Repository", selection: $selectedRepoPath) {
                        ForEach(visibleRepos, id: \.path) { repo in
                            Text(repo.displayName).tag(Optional(repo.path))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            Section("Worktree name") {
                TextField("feature-xyz", text: $worktreeName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: worktreeName) { _, new in
                        let sanitized = WorktreeNameSanitizer.sanitize(new)
                        if sanitized != new {
                            worktreeName = sanitized
                            return
                        }
                        if branchMode == .newBranch && branchMirrorsWorktree && branchName != sanitized {
                            branchName = sanitized
                        }
                    }
            }
            Section("Branch") {
                Picker("Mode", selection: $branchMode) {
                    Text("New branch").tag(BranchMode.newBranch)
                    Text("Existing branch").tag(BranchMode.existing)
                }
                .pickerStyle(.segmented)

                if branchMode == .newBranch {
                    TextField("feature-xyz", text: $branchName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: branchName) { _, new in
                            let sanitized = WorktreeNameSanitizer.sanitize(new)
                            if sanitized != new {
                                branchName = sanitized
                                return
                            }
                            if sanitized != worktreeName {
                                branchMirrorsWorktree = false
                            }
                        }
                } else {
                    TextField("existing-branch-name", text: $branchName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: branchName) { _, new in
                            let sanitized = WorktreeNameSanitizer.sanitize(new)
                            if sanitized != new {
                                branchName = sanitized
                            }
                        }
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .submitLabel(.done)
        .onSubmit { submitFromReturn() }
        .onChange(of: selectedTargetID) { _, targetID in
            let candidates = repositories(on: targetID, from: repos)
            if !candidates.contains(where: { $0.path == selectedRepoPath }) {
                selectedRepoPath = candidates.first?.path
            }
        }
    }

    private var canSubmit: Bool {
        guard !isSubmitting, selectedRepoPath != nil else { return false }
        return !WorktreeNameSanitizer.trimForSubmit(worktreeName).isEmpty
            && !WorktreeNameSanitizer.trimForSubmit(branchName).isEmpty
    }

    private func loadRepos() async {
        reposState = .loading
        do {
            let repos = try await ReposFetcher.fetch(baseURL: host.baseURL)
            reposState = .loaded(repos)
            let selectedRepo = repos.first { $0.path == selectedRepoPath }
            selectedTargetID = selectedRepo.map(targetID(for:))
                ?? targetMacs(in: repos).first?.id
            if !repos.contains(where: { $0.path == selectedRepoPath }) {
                selectedRepoPath = repositories(
                    on: selectedTargetID,
                    from: repos
                ).first?.path
            }
        } catch let err as ReposFetcher.FetchError {
            reposState = .error(err.userMessage)
        } catch {
            reposState = .error(ReposFetcher.FetchError.transport.userMessage)
        }
    }

    private func targetID(for repo: ReposFetcher.RepoInfo) -> String {
        repo.origin.map { "device:\($0.deviceID.value)" }
            ?? "legacy:connected-mac"
    }

    private func targetMacs(
        in repos: [ReposFetcher.RepoInfo]
    ) -> [TargetMac] {
        var seen: Set<String> = []
        return repos.compactMap { repo in
            let id = targetID(for: repo)
            guard seen.insert(id).inserted else { return nil }
            return TargetMac(
                id: id,
                label: repo.origin?.deviceLabel ?? host.label
            )
        }
    }

    private func repositories(
        on targetID: String?,
        from repos: [ReposFetcher.RepoInfo]
    ) -> [ReposFetcher.RepoInfo] {
        guard let targetID else { return [] }
        return repos.filter { self.targetID(for: $0) == targetID }
    }

    private func submitFromReturn() {
        guard Self.shouldSubmitOnReturn(canSubmit: canSubmit, isSubmitting: isSubmitting) else { return }
        Task { await submit() }
    }

    private func submit() async {
        guard canSubmit else { return }
        guard let repoPath = selectedRepoPath else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let body = CreateWorktreeClient.Request(
            repoPath: repoPath,
            worktreeName: WorktreeNameSanitizer.trimForSubmit(worktreeName),
            branchName: WorktreeNameSanitizer.trimForSubmit(branchName),
            existing: branchMode == .existing
        )
        do {
            let response = try await CreateWorktreeClient.create(baseURL: host.baseURL, body: body)
            onCreated(response)
            dismiss()
        } catch let err as CreateWorktreeClient.CreateError {
            errorMessage = err.userMessage
        } catch {
            errorMessage = CreateWorktreeClient.CreateError.transport.userMessage
        }
    }
}
#endif
