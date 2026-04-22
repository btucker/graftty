#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// First "inside a host" screen — one row per running worktree, grouped
/// by repo name to mirror the Mac sidebar. Tapping a row pushes a
/// worktree-scoped destination where the user sees the pane split tree.
public struct WorktreePickerView: View {
    @State private var state: LoadState = .loading
    public let host: Host
    public let onSelect: (WorktreePanes) -> Void

    public init(host: Host, onSelect: @escaping (WorktreePanes) -> Void) {
        self.host = host
        self.onSelect = onSelect
    }

    private enum LoadState {
        case loading
        case loaded([WorktreePanes])
        case error(String)
    }

    public var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .error(let msg):
                ContentUnavailableView {
                    Label("Couldn't load worktrees", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded(let worktrees):
                List {
                    ForEach(grouped(worktrees), id: \.0) { repoName, entries in
                        Section(repoName) {
                            ForEach(entries, id: \.path) { wt in
                                Button {
                                    onSelect(wt)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(wt.displayName).font(.body)
                                        Text(wt.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(host.label)
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let list = try await WorktreePanesFetcher.fetch(baseURL: host.baseURL)
            state = .loaded(list)
        } catch WorktreePanesFetcher.FetchError.forbidden {
            state = .error("Not authorized — is this device on your tailnet?")
        } catch WorktreePanesFetcher.FetchError.http(let code) {
            state = .error("HTTP \(code)")
        } catch WorktreePanesFetcher.FetchError.decode {
            state = .error("The server sent a response this version can't read.")
        } catch {
            state = .error("Couldn't reach the server.")
        }
    }

    private func grouped(_ list: [WorktreePanes]) -> [(String, [WorktreePanes])] {
        Dictionary(grouping: list, by: \.repoDisplayName)
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }
}
#endif
