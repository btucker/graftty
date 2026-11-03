#if canImport(UIKit)
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI

/// @spec REMOTE-13.10: When GrafttyMobile creates a worktree, the Add Worktree sheet shall ask for the project first, then the host when the project is on several, loading each host's own branches.
public struct AddWorktreeSheetView: View {

    /// One checkout of the project, reached through the host that reported it.
    public struct Route: Identifiable {
        public let choice: AddWorktreeHostChoice
        public let host: Host
        public let provider: RemoteConnectionProvider
        public let repositoryID: String
        public var id: String { choice.id }
    }

    public struct Target: Identifiable {
        public let id: String
        public let name: String
        public let routes: [Route]
    }

    public let targets: [Target]
    public let initialProjectID: String?
    public struct Submission {
        public let request: CreateWorktreeClient.Request
        public let repository: RemoteRepositoryInfo
        public let existingSource: RemoteRepositoryInfo.Branch.Source?
        public let route: Route
    }

    public let onSubmit: (Submission) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reposState: ReposState = .loading
    @State private var selectedProjectID: String?
    @State private var selectedRouteID: String?
    @State private var selectedRepoPath: String?
    @State private var worktreeName: String = ""
    @State private var branchName: String = ""
    /// Once the user types a branch that differs from the worktree name,
    /// stop auto-syncing so their edit sticks.
    @State private var branchMirrorsWorktree: Bool = true
    @State private var branchMode: BranchMode = .newBranch
    @State private var isSubmitting: Bool = false
    @State private var submissionTask: Task<Void, Never>?
    @State private var agent = WorktreeAgentConfiguration()
    @FocusState private var taskDescriptionFocused: Bool

    enum BranchMode { case newBranch, existing }

    public init(
        targets: [Target],
        initialProjectID: String?,
        onSubmit: @escaping (Submission) -> Void
    ) {
        self.targets = targets
        self.initialProjectID = initialProjectID
        self.onSubmit = onSubmit
        _selectedProjectID = State(initialValue: initialProjectID ?? (targets.count == 1 ? targets[0].id : nil))
    }

    private var routes: [Route] { targets.first { $0.id == selectedProjectID }?.routes ?? [] }
    private var selectedRoute: Route? { routes.first { $0.id == selectedRouteID } }

    /// Opening the sheet only dials a sleeping host when every host is asleep.
    private func chooseDefaultRoute() {
        guard let selectedProjectID else { selectedRouteID = nil; return }
        let lastUsed = UserDefaults.standard.string(forKey: "addWorktree.lastHost.\(selectedProjectID)")
        selectedRouteID = AddWorktreeHostChoice.defaultChoice(AddWorktreeHostChoice.labeled(routes.map(\.choice)), lastUsedID: lastUsed)?.choice.id
    }

    public static func shouldSubmitOnReturn(canSubmit: Bool, isSubmitting: Bool, editingTaskDescription: Bool = false) -> Bool {
        canSubmit && !isSubmitting && !editingTaskDescription
    }

    /// A typed branch name carries to the next host only if that host has it.
    static func carriedBranch(_ name: String, existing: Bool, in repository: RemoteRepositoryInfo?) -> String {
        guard existing, repository?.branches.contains(where: { $0.name == name }) != true else { return name }
        return ""
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
        case noSelection
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
                case .noSelection:
                    form(repos: [])
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
                    Button("Cancel") {
                        submissionTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create") { submit() }
                            .keyboardShortcut(.return, modifiers: taskDescriptionFocused ? .command : [])
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear { if selectedRouteID == nil { chooseDefaultRoute() } }
            .onChange(of: selectedProjectID) { _, _ in chooseDefaultRoute() }
            .task(id: selectedRouteID) { await loadRepos() }
            .onDisappear { submissionTask?.cancel() }
        }
    }

    @ViewBuilder
    private func form(repos: [RemoteRepositoryInfo]) -> some View {
        let choices = AddWorktreeHostChoice.labeled(routes.map(\.choice))
        Form {
            if initialProjectID == nil, targets.count > 1 {
                Section("Project") {
                    Picker("Project", selection: $selectedProjectID) {
                        Text("Select a project").tag(String?.none)
                        ForEach(targets) { target in Text(target.name).tag(Optional(target.id)) }
                    }
                    .pickerStyle(.menu)
                }
            }
            if AddWorktreeHostChoice.showsRow(choices) {
                Section("Host") {
                    Picker("Host", selection: $selectedRouteID) {
                        ForEach(choices) { choice in
                            Text(choice.label).tag(Optional(choice.id)).selectionDisabled(!choice.isSelectable)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            Section("Worktree name") {
                TextField("Automatic if blank", text: $worktreeName)
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
            Section("Agent") {
                Picker("Agent", selection: $agent.provider) {
                    Text("Default agent").tag(String?.none)
                    Text("Codex").tag(Optional("codex"))
                    Text("Claude").tag(Optional("claude"))
                }
            }
            Section {
                TextEditor(text: $agent.taskDescription)
                    .focused($taskDescriptionFocused)
                    .submitLabel(.return)
                    .frame(minHeight: 100)
                    .accessibilityLabel("What do you want to do?")
            } header: {
                Text("What do you want to do?")
            } footer: {
                Text("Optional. Sent as the agent's first message.")
            }
        }
        .submitLabel(.done)
        .onSubmit { submitFromReturn() }
    }

    private var canSubmit: Bool {
        guard !isSubmitting, selectedRepoPath != nil else { return false }
        return WorktreeNameSuggestion.canSubmit(
            worktreeName: worktreeName, branchName: branchName, existing: branchMode == .existing
        )
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
        guard let route = selectedRoute else {
            // Nothing to load until a project is chosen.
            reposState = targets.isEmpty ? .loaded([]) : .noSelection
            return
        }
        reposState = .loading
        do {
            let repos = try await Self.loadRepositories(using: route.provider)
            guard !Task.isCancelled else { return }
            reposState = .loaded(repos)
            selectedRepoPath = route.repositoryID
            branchName = Self.carriedBranch(branchName, existing: branchMode == .existing, in: repos.first { $0.id == route.repositoryID })
        } catch is CancellationError {
            return
        } catch RepositoryLoadError.unexpectedResponse {
            reposState = .error("The paired Mac returned an unexpected response.")
        } catch {
            reposState = .error("Couldn't reach \(route.choice.host).")
        }
    }

    private func submitFromReturn() {
        guard Self.shouldSubmitOnReturn(canSubmit: canSubmit, isSubmitting: isSubmitting,
                                        editingTaskDescription: taskDescriptionFocused) else { return }
        submit()
    }

    private func submit() {
        guard canSubmit, let repoPath = selectedRepoPath, let route = selectedRoute,
              case .loaded(let repositories) = reposState,
              let repository = repositories.first(where: { $0.id == repoPath }) else { return }
        isSubmitting = true
        let configuration = agent
        let existing = branchMode == .existing
        let name = worktreeName
        let branch = branchName
        submissionTask = Task { @MainActor in
            defer { isSubmitting = false }
            do {
                let names = try await WorktreeNameSuggestion.resolve(
                    worktreeName: name, branchName: branch, existing: existing,
                    repositoryName: repository.displayName, taskDescription: configuration.taskDescription,
                    reservedNames: Set(repository.branches.map(\.name))
                )
                try Task.checkCancellation()
                let request = CreateWorktreeClient.Request(
                    repoPath: repoPath, worktreeName: names.worktree, branchName: names.branch,
                    existing: existing, agent: configuration
                )
                if let projectID = selectedProjectID {
                    UserDefaults.standard.set(route.id, forKey: "addWorktree.lastHost.\(projectID)")
                }
                onSubmit(Submission(
                    request: request, repository: repository,
                    existingSource: existing
                        ? Self.existingBranchSource(repositoryID: repoPath, branchName: names.branch, repositories: repositories)
                        : nil,
                    route: route
                ))
                dismiss()
            } catch {
                // Name resolution only throws on cancellation. No request was sent.
            }
        }
    }
}
#endif
