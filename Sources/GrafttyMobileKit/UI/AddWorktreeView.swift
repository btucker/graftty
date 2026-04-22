#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// SwiftUI parallel of the Mac `AddWorktreeSheet` and web `/new` route.
/// First-class mobile citizen: the worktree picker pushes this view onto
/// the navigation stack rather than presenting a sheet, so the iOS
/// NavigationStack's system back affordance (swipe-from-edge + back
/// chevron) is available throughout.
///
/// Parity notes with the Mac sheet:
/// - Branch field auto-mirrors the worktree name until the user types a
///   differing branch name, after which it sticks.
/// - Input is sanitized live through `WorktreeNameSanitizer` so a paste
///   of `my feature/foo!` becomes `my-feature-foo-` as it lands.
/// - Trim-on-submit strips leading/trailing whitespace, dashes, and
///   dots, matching the Mac sheet's `submitTrimSet`.
public struct AddWorktreeView: View {
    public let host: Host
    public let onCreated: (_ sessionName: String) -> Void

    @State private var reposState: ReposState = .loading
    @State private var selectedRepoPath: String = ""
    @State private var worktreeName: String = ""
    @State private var branchName: String = ""
    @State private var branchMirrors: Bool = true
    @State private var submitting: Bool = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    public init(host: Host, onCreated: @escaping (_ sessionName: String) -> Void) {
        self.host = host
        self.onCreated = onCreated
    }

    private enum ReposState {
        case loading
        case loaded([RepoInfo])
        case error(String)
    }

    /// Characters stripped from either end at submit time. Mirrors the
    /// Mac sheet's `submitTrimSet` — we don't trim as-you-type because
    /// that would eat the separator a user has just typed between
    /// words.
    private static let submitTrimSet: CharacterSet = {
        var set = CharacterSet.whitespaces
        set.insert(charactersIn: "-.")
        return set
    }()

    public var body: some View {
        Form {
            switch reposState {
            case .loading:
                Section { ProgressView() }
            case .error(let msg):
                Section {
                    Label("Couldn't load repositories", systemImage: "exclamationmark.triangle")
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await loadRepos() } }
                }
            case .loaded(let repos):
                if repos.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No repositories",
                            systemImage: "externaldrive",
                            description: Text("Open a repository in Graftty on the Mac first.")
                        )
                    }
                } else {
                    loadedForm(repos: repos)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add worktree")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if submitting {
                        ProgressView()
                    } else {
                        Text("Create")
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .task { await loadRepos() }
    }

    @ViewBuilder
    private func loadedForm(repos: [RepoInfo]) -> some View {
        if repos.count > 1 {
            Section("Repository") {
                Picker("Repository", selection: $selectedRepoPath) {
                    ForEach(repos, id: \.path) { repo in
                        Text(repo.displayName).tag(repo.path)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        Section("Worktree name") {
            TextField("feature-xyz", text: $worktreeName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .disabled(submitting)
                .onChange(of: worktreeName) { _, new in
                    let sanitized = WorktreeNameSanitizer.sanitize(new)
                    if sanitized != new {
                        worktreeName = sanitized
                        return
                    }
                    if branchMirrors {
                        branchName = sanitized
                    }
                }
        }
        Section("Branch") {
            TextField("feature-xyz", text: $branchName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .disabled(submitting)
                .onChange(of: branchName) { _, new in
                    let sanitized = WorktreeNameSanitizer.sanitize(new)
                    if sanitized != new {
                        branchName = sanitized
                        return
                    }
                    if sanitized != worktreeName {
                        branchMirrors = false
                    }
                }
        }
    }

    private var canSubmit: Bool {
        if submitting { return false }
        if selectedRepoPath.isEmpty { return false }
        let wt = worktreeName.trimmingCharacters(in: Self.submitTrimSet)
        let br = branchName.trimmingCharacters(in: Self.submitTrimSet)
        return !wt.isEmpty && !br.isEmpty
    }

    private func loadRepos() async {
        reposState = .loading
        do {
            let repos = try await ReposFetcher.fetch(baseURL: host.baseURL)
            reposState = .loaded(repos)
            if selectedRepoPath.isEmpty, let first = repos.first {
                selectedRepoPath = first.path
            }
        } catch ReposFetcher.FetchError.forbidden {
            reposState = .error("Not authorized — is this device on your tailnet?")
        } catch ReposFetcher.FetchError.http(let code) {
            reposState = .error("HTTP \(code)")
        } catch ReposFetcher.FetchError.decode {
            reposState = .error("The server sent a response this version can't read.")
        } catch {
            reposState = .error("Couldn't reach the server.")
        }
    }

    private func submit() async {
        errorMessage = nil
        submitting = true
        defer { submitting = false }

        let wt = worktreeName.trimmingCharacters(in: Self.submitTrimSet)
        let br = branchName.trimmingCharacters(in: Self.submitTrimSet)
        let body = CreateWorktreeRequest(
            repoPath: selectedRepoPath,
            worktreeName: wt,
            branchName: br
        )
        do {
            let response = try await WorktreeCreator.create(baseURL: host.baseURL, body: body)
            onCreated(response.sessionName)
        } catch WorktreeCreator.CreateError.http(_, let msg) {
            errorMessage = msg
        } catch WorktreeCreator.CreateError.forbidden {
            errorMessage = "Not authorized — is this device on your tailnet?"
        } catch WorktreeCreator.CreateError.decode {
            errorMessage = "The server sent a response this version can't read."
        } catch {
            errorMessage = "Couldn't reach the server."
        }
    }
}
#endif
