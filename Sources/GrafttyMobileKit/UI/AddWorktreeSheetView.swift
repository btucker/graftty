#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// @spec REMOTE-13.10: When GrafttyMobile creates a worktree while the
/// connected Mac exposes repositories from multiple Macs, the Add Worktree
/// sheet shall require an explicit target Mac selection before repository
/// selection and creation.
public struct AddWorktreeSheetView: View {

    public let host: Host
    public let remoteConnectionProvider: RemoteConnectionProvider?
    public struct Submission {
        public let request: CreateWorktreeClient.Request
        public let repository: RemoteRepositoryInfo
        public let existingSource: RemoteRepositoryInfo.Branch.Source?
    }

    public let onSubmit: (Submission) -> Void

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

    enum BranchMode { case newBranch, existing }

    private struct TargetMac: Identifiable {
        let id: String
        let label: String
    }

    public init(
        host: Host,
        remoteConnectionProvider: RemoteConnectionProvider?,
        onSubmit: @escaping (Submission) -> Void
    ) {
        self.host = host
        self.remoteConnectionProvider = remoteConnectionProvider
        self.onSubmit = onSubmit
    }

    public static func shouldSubmitOnReturn(canSubmit: Bool, isSubmitting: Bool) -> Bool {
        canSubmit && !isSubmitting
    }

    static func initialTargetID(
        preservedTargetID: String?,
        targetIDs: [String]
    ) -> String? {
        if let preservedTargetID,
           targetIDs.contains(preservedTargetID) {
            return preservedTargetID
        }
        return targetIDs.count == 1 ? targetIDs[0] : nil
    }

    static func existingBranchSource(
        repositoryID: String,
        branchName: String,
        repositories: [RemoteRepositoryInfo]
    ) -> RemoteRepositoryInfo.Branch.Source {
        repositories.first(where: { $0.id == repositoryID })?
            .branches
            .first(where: { $0.name == branchName })?
            .source ?? .automatic
    }

    private enum ReposState {
        case loading
        case loaded([RemoteRepositoryInfo])
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
                        Button("Create") { submit() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSubmit)
                    }
                }
            }
            .task { await loadRepos() }
        }
    }

    @ViewBuilder
    private func form(repos: [RemoteRepositoryInfo]) -> some View {
        let targets = targetMacs(in: repos)
        let visibleRepos = repositories(on: selectedTargetID, from: repos)
        Form {
            if targets.count > 1 {
                Section("Target Mac") {
                    Picker("Mac", selection: $selectedTargetID) {
                        Text("Select a Mac").tag(String?.none)
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
                        ForEach(visibleRepos, id: \.id) { repo in
                            Text(repo.displayName).tag(Optional(repo.id))
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
        }
        .submitLabel(.done)
        .onSubmit { submitFromReturn() }
        .onChange(of: selectedTargetID) { _, targetID in
            let candidates = repositories(on: targetID, from: repos)
            if !candidates.contains(where: { $0.id == selectedRepoPath }) {
                selectedRepoPath = candidates.first?.id
            }
        }
    }

    private var canSubmit: Bool {
        guard !isSubmitting, selectedRepoPath != nil else { return false }
        return !WorktreeNameSanitizer.trimForSubmit(worktreeName).isEmpty
            && !WorktreeNameSanitizer.trimForSubmit(branchName).isEmpty
    }

    enum RepositoryLoadError: Error {
        case unexpectedResponse
    }

    /// IOS-9.17: repositories come only from the authenticated paired
    /// connection; with none, the list fails closed.
    static func loadRepositories(
        using provider: RemoteConnectionProvider?
    ) async throws -> [RemoteRepositoryInfo] {
        let response = try await RelayedWorktreeManagementClient.send(
            .listRepositories,
            using: provider
        )
        guard case .repositories(let remoteRepositories) = response else {
            throw RepositoryLoadError.unexpectedResponse
        }
        return remoteRepositories
    }

    private func loadRepos() async {
        reposState = .loading
        do {
            let repos = try await Self.loadRepositories(using: remoteConnectionProvider)
            reposState = .loaded(repos)
            let selectedRepo = repos.first { $0.id == selectedRepoPath }
            let targets = targetMacs(in: repos)
            let preservedTarget = selectedRepo.map(targetID(for:))
            selectedTargetID = Self.initialTargetID(
                preservedTargetID: preservedTarget,
                targetIDs: targets.map(\.id)
            )
            if !repos.contains(where: { $0.id == selectedRepoPath }) {
                selectedRepoPath = repositories(
                    on: selectedTargetID,
                    from: repos
                ).first?.id
            }
        } catch RepositoryLoadError.unexpectedResponse {
            reposState = .error("The paired Mac returned an unexpected response.")
        } catch {
            reposState = .error("Couldn't reach the server.")
        }
    }

    private func targetID(for repo: RemoteRepositoryInfo) -> String {
        repo.origin.map { "device:\($0.deviceID.value)" }
            ?? "legacy:connected-mac"
    }

    private func targetMacs(
        in repos: [RemoteRepositoryInfo]
    ) -> [TargetMac] {
        var seen: Set<String> = []
        let targets = repos.compactMap { repo -> TargetMac? in
            let id = targetID(for: repo)
            guard seen.insert(id).inserted else { return nil }
            return TargetMac(
                id: id,
                label: repo.origin?.deviceLabel ?? host.label
            )
        }
        let counts = Dictionary(grouping: targets, by: \.label)
            .mapValues(\.count)
        return targets.map { target in
            guard counts[target.label, default: 0] > 1 else { return target }
            let ownerID = target.id.split(separator: ":").last
                .map { String($0.prefix(6)) } ?? target.id
            return TargetMac(
                id: target.id,
                label: "\(target.label) (\(ownerID))"
            )
        }
    }

    private func repositories(
        on targetID: String?,
        from repos: [RemoteRepositoryInfo]
    ) -> [RemoteRepositoryInfo] {
        guard let targetID else { return [] }
        return repos.filter { self.targetID(for: $0) == targetID }
    }

    private func submitFromReturn() {
        guard Self.shouldSubmitOnReturn(canSubmit: canSubmit, isSubmitting: isSubmitting) else { return }
        submit()
    }

    private func submit() {
        guard canSubmit, let repoPath = selectedRepoPath,
              case .loaded(let repositories) = reposState,
              let repository = repositories.first(where: { $0.id == repoPath }) else { return }
        isSubmitting = true
        let request = CreateWorktreeClient.Request(
            repoPath: repoPath,
            worktreeName: WorktreeNameSanitizer.trimForSubmit(worktreeName),
            branchName: WorktreeNameSanitizer.trimForSubmit(branchName),
            existing: branchMode == .existing
        )
        onSubmit(Submission(
            request: request,
            repository: repository,
            existingSource: request.existing
                ? existingBranchSource(repositoryID: repoPath, branchName: request.branchName)
                : nil
        ))
        dismiss()
    }

    private func existingBranchSource(
        repositoryID: String,
        branchName: String
    ) -> RemoteRepositoryInfo.Branch.Source {
        guard case .loaded(let repositories) = reposState else {
            return .automatic
        }
        // Known branches use their advertised source. A missing or stale
        // snapshot asks the owning Mac to resolve exact refs.
        return Self.existingBranchSource(
            repositoryID: repositoryID,
            branchName: branchName,
            repositories: repositories
        )
    }
}
#endif
