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
struct WorktreeNavigationHistory {
    private var visits: [WorktreeNavigationTarget] = []
    private var currentIndex: Int?
    private var isShowingCurrent = false
    private(set) var recentTargets: [WorktreeNavigationTarget] = []

    mutating func record(_ target: WorktreeNavigationTarget?) {
        guard let target else {
            isShowingCurrent = false
            return
        }
        if let currentIndex, visits[currentIndex] == target {
            isShowingCurrent = true
            noteRecent(target)
            return
        }
        if let currentIndex { visits.removeSubrange((currentIndex + 1)..<visits.count) }
        visits.append(target)
        if visits.count > 100 { visits.removeFirst(visits.count - 100) }
        currentIndex = visits.count - 1
        isShowingCurrent = true
        noteRecent(target)
    }

    func target(forward: Bool, isAvailable: (WorktreeNavigationTarget) -> Bool = { _ in true }) -> WorktreeNavigationTarget? {
        destinationIndex(forward: forward, isAvailable: isAvailable).map { visits[$0] }
    }

    mutating func navigate(forward: Bool, isAvailable: (WorktreeNavigationTarget) -> Bool = { _ in true }) -> WorktreeNavigationTarget? {
        guard let index = destinationIndex(forward: forward, isAvailable: isAvailable) else { return nil }
        currentIndex = index
        isShowingCurrent = true
        let target = visits[index]
        noteRecent(target)
        return target
    }

    private func destinationIndex(forward: Bool, isAvailable: (WorktreeNavigationTarget) -> Bool) -> Int? {
        guard let currentIndex else { return nil }
        let step = forward ? 1 : -1
        var index = currentIndex + (forward || isShowingCurrent ? step : 0)
        while visits.indices.contains(index) {
            // Skip unavailable destinations and repeated visits to the same
            // worktree exposed by a removed intermediate destination.
            if (!isShowingCurrent || visits[index] != visits[currentIndex]), isAvailable(visits[index]) {
                return index
            }
            index += step
        }
        return nil
    }

    private mutating func noteRecent(_ target: WorktreeNavigationTarget) {
        recentTargets.removeAll { $0 == target }
        recentTargets.insert(target, at: 0)
        if recentTargets.count > 20 { recentTargets.removeLast(recentTargets.count - 20) }
    }
}
