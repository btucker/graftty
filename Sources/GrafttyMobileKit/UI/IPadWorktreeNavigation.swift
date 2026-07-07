#if canImport(UIKit)
import GrafttyProtocol

public enum IPadWorktreeNavigation {
    public static func nextPath(
        in list: [WorktreePanes],
        selectedPath: String?,
        forward: Bool
    ) -> String? {
        let selectable = list.filter { $0.state.hasOnDiskWorktree }
        let count = selectable.count
        guard count > 0 else { return nil }
        if count == 1 {
            let onlyPath = selectable[0].path
            return onlyPath == selectedPath ? nil : onlyPath
        }

        let selectedIndex = selectedPath.flatMap { path in
            selectable.firstIndex { $0.path == path }
        }
        let searchOrder = orderedIndices(count: count, selectedIndex: selectedIndex, forward: forward)

        if let attentionIndex = searchOrder.first(where: { index in
            let wt = selectable[index]
            return wt.path != selectedPath && hasAttention(wt)
        }) {
            return selectable[attentionIndex].path
        }

        return selectable[searchOrder[0]].path
    }

    private static func orderedIndices(
        count: Int,
        selectedIndex: Int?,
        forward: Bool
    ) -> [Int] {
        if let selectedIndex {
            return (1...(count - 1)).map { step in
                forward
                    ? (selectedIndex + step) % count
                    : (selectedIndex - step + count) % count
            }
        }
        return forward ? Array(0..<count) : Array((0..<count).reversed())
    }

    private static func hasAttention(_ wt: WorktreePanes) -> Bool {
        if wt.attentionText != nil { return true }
        return wt.layout?.leaves.contains { $0.attentionText != nil } ?? false
    }
}
#endif
