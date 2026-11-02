import GrafttyProtocol

/// Remote identity includes the pairing fingerprint so a replaced Mac
/// cannot inherit visits recorded for an earlier pairing.
enum WorktreeNavigationTarget: Hashable {
    case local(String)
    case remote(RemoteMacIdentity, String)

    var path: String {
        switch self {
        case .local(let path), .remote(_, let path): return path
        }
    }
}

struct BreadcrumbHistoryItem: Identifiable {
    let target: WorktreeNavigationTarget
    let repoName: String
    let worktreeName: String
    let branchName: String
    let remoteMacName: String?

    var id: WorktreeNavigationTarget { target }
    var path: String { target.path }
    var menuTitle: String {
        let title = "\(repoName) / \(worktreeName) (\(branchName))"
        return remoteMacName.map { "\(title) · \($0)" } ?? title
    }
}

/// Browser history and distinct recents serve different purposes. Recents
/// retain destinations discarded by a new visit after Back.
typealias WorktreeNavigationHistory = NavigationHistory<WorktreeNavigationTarget>
