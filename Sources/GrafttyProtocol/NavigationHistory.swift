/// Back/forward history of visited destinations, as in a browser. Shared by
/// the Mac breadcrumb and the iPad toolbar.
public struct NavigationHistory<Target: Hashable> {
    private var visits: [Target] = []
    private var currentIndex: Int?
    private var isShowingCurrent = false
    public private(set) var recentTargets: [Target] = []

    public init() {}

    public mutating func record(_ target: Target?) {
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

    public func target(forward: Bool, isAvailable: (Target) -> Bool = { _ in true }) -> Target? {
        destinationIndex(forward: forward, isAvailable: isAvailable).map { visits[$0] }
    }

    public mutating func navigate(forward: Bool, isAvailable: (Target) -> Bool = { _ in true }) -> Target? {
        guard let index = destinationIndex(forward: forward, isAvailable: isAvailable) else { return nil }
        currentIndex = index
        isShowingCurrent = true
        let target = visits[index]
        noteRecent(target)
        return target
    }

    private func destinationIndex(forward: Bool, isAvailable: (Target) -> Bool) -> Int? {
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

    private mutating func noteRecent(_ target: Target) {
        recentTargets.removeAll { $0 == target }
        recentTargets.insert(target, at: 0)
        if recentTargets.count > 20 { recentTargets.removeLast(recentTargets.count - 20) }
    }
}
