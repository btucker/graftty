import Foundation
import GrafttyProtocol

public enum BranchPickerViewModel {
    /// Build the sorted, filtered, dimmed entry list for the picker.
    /// Pure; no SwiftUI, no MainActor.
    public static func entries(
        branchSnapshot: RemoteBranchSnapshot,
        mountedBranchToPath: [String: String],
        prsByBranch: [String: PRInfo],
        filterText: String
    ) -> [BranchPickerEntry] {
        // Local wins on collision — local ref is what `git worktree add` will use.
        var byName: [String: BranchPickerEntry] = [:]
        for ref in branchSnapshot.localBranches {
            guard Self.isEligibleBranchName(ref.name) else { continue }
            byName[ref.name] = build(
                ref: ref,
                source: .local,
                mounted: mountedBranchToPath[ref.name],
                pr: prsByBranch[ref.name]
            )
        }
        for ref in branchSnapshot.remoteBranches {
            guard byName[ref.name] == nil else { continue }
            guard Self.isEligibleBranchName(ref.name) else { continue }
            byName[ref.name] = build(
                ref: ref,
                source: .remoteOnly,
                mounted: mountedBranchToPath[ref.name],
                pr: prsByBranch[ref.name]
            )
        }

        var result = Array(byName.values)
        if !filterText.isEmpty {
            let needle = filterText.lowercased()
            result = result.filter { $0.name.lowercased().contains(needle) }
        }
        result.sort { lhs, rhs in
            if lhs.lastCommitDate != rhs.lastCommitDate {
                return lhs.lastCommitDate > rhs.lastCommitDate
            }
            return lhs.name < rhs.name
        }
        return result
    }

    private static func build(
        ref: BranchRef,
        source: BranchSelection.ExistingSource,
        mounted: String?,
        pr: PRInfo?
    ) -> BranchPickerEntry {
        let summary = pr.map { BranchPickerEntry.PRSummary(number: $0.number, title: $0.title) }
        return BranchPickerEntry(
            name: ref.name,
            source: source,
            lastCommitDate: ref.lastCommitDate,
            mountedWorktreePath: mounted,
            pr: summary
        )
    }

    private static func isEligibleBranchName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") { return false }
        return true
    }
}
