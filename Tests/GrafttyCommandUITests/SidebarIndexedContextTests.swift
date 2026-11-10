import Foundation
import Observation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct SidebarIndexedContextTests {
    @Test func currentContentAndRetainedInputsMatchUnindexedProjection() throws {
        let suite = "sidebar-indexed-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let project = SidebarProject(id: "p", repositoryID: "repo", name: "Project")
        let original = row(stop: stop(100))
        let old = navigation.worktreeContext(original)
        navigation.reconcile(worktrees: [original], projects: [project])
        assertEquivalent(navigation, original, defaults)
        navigation.opened(old.item)
        assertEquivalent(navigation, original, defaults)
        navigation.dismissRequest(in: old)
        assertEquivalent(navigation, original, defaults)
        #expect(navigation.worktreeContext(original).pending.isEmpty)

        let newer = row(stop: stop(110))
        navigation.updateAttentionItems(SidebarProjection.activity([newer]))
        navigation.dismissRequest(in: old)
        assertEquivalent(navigation, newer, defaults)
        #expect(navigation.worktreeContext(newer).pending.count == 1)
        #expect(navigation.nextPendingWorktree(in: [original, newer], projectID: "p", after: nil) == nil)
        // Deduplication keeps the first displayed row, whose occurrence was superseded.
        #expect(navigation.nextPendingWorktree(in: [newer], projectID: "p", after: nil)?.worktreeID == newer.path)

        for changed in [row(name: "Renamed", stop: stop(110)), row(stop: stop(110), progress: ["agent": 120]),
                        row(stop: stop(110), state: .closed), row(path: "/moved"), row(id: "replacement"),
                        row(project: "remote", id: "remote-stable")] {
            assertEquivalent(navigation, changed, defaults)
            #expect(navigation.worktreeContext(changed).worktree == changed)
        }
        let resumed = row(stop: stop(110), progress: ["agent": 120])
        #expect(navigation.worktreeContext(resumed).pending.isEmpty)
        #expect(navigation.worktreeContext(resumed).isRunning)
        #expect(navigation.worktreeContext(row(name: "Renamed", stop: stop(110))).matches(query: "Renamed"))

        let routine = row(stop: stop(130, need: nil))
        navigation.updateAttentionItems([SidebarWorktreeContext(worktree: routine).item])
        let withoutLiveStop = row()
        assertEquivalent(navigation, withoutLiveStop, defaults)
        #expect(navigation.worktreeContext(withoutLiveStop).item.agentStop?.timestamp == 130)
        // Replacing a report at the same timestamp must update its content too.
        let replacement = row(stop: stop(130, title: "Revised recap", need: nil))
        navigation.updateAttentionItems([SidebarWorktreeContext(worktree: replacement).item])
        assertEquivalent(navigation, withoutLiveStop, defaults)
        #expect(navigation.worktreeContext(withoutLiveStop).matches(query: "Revised recap"))
        navigation.reconcile(worktrees: [], projects: [.init(id: "p", repositoryID: "repo", name: "Project", isAvailable: false)])
        assertEquivalent(navigation, withoutLiveStop, defaults)
        #expect(navigation.worktreeContext(withoutLiveStop).item.agentStop != nil)
        navigation.reconcile(worktrees: [], projects: [project])
        assertEquivalent(navigation, withoutLiveStop, defaults)
        #expect(navigation.worktreeContext(withoutLiveStop).item.agentStop == nil)
    }

    @Test func readsKeepObservationAndDoNotPublishDuringProjection() throws {
        let suite = "sidebar-observation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let unchangedRow = row()
        let changes = ChangeCount()
        func track() {
            withObservationTracking {
                _ = navigation.worktreeContext(unchangedRow)
            } onChange: { changes.increment() }
        }
        track()
        for _ in 0..<5 { _ = navigation.worktreeContext(unchangedRow) }
        #expect(changes.value == 0)
        let routine = row(stop: stop(100, need: nil))
        navigation.updateAttentionItems([SidebarWorktreeContext(worktree: routine).item])
        #expect(changes.value == 1)
        track()
        let request = row(stop: stop(110))
        navigation.reconcile(worktrees: [request], projects: [.init(id: "p", repositoryID: "repo", name: "Project")])
        #expect(changes.value == 2)
        track()
        navigation.dismissRequest(in: navigation.worktreeContext(request))
        #expect(changes.value == 3)
    }

    @Test func openingNotificationStillObservesHistory() throws {
        let suite = "sidebar-history-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let notice = WorktreePanes(path: "/notice", displayName: "Notice", repoDisplayName: "Project", displayBranch: "notice",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
            attentionText: "Read me", attentionSource: .userNotify, layout: nil)
        let item = try #require(navigation.worktreeContext(notice).pending.first)
        navigation.updateAttentionItems([item])
        let changes = ChangeCount()
        withObservationTracking {
            #expect(navigation.worktreeContext(notice).pending.count == 1)
        } onChange: { changes.increment() }
        navigation.opened(item)
        #expect(changes.value == 1)
        #expect(navigation.worktreeContext(notice).pending.isEmpty)
    }

    @Test func restoredLegacyReportsStayScopedToTheirHostAndRepository() throws {
        let suite = "sidebar-legacy-index-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows: [WorktreePanes] = ["local", "remote"].flatMap { host -> [WorktreePanes] in
            ["repo", "other-repo"].map { repository in
                WorktreePanes(path: "/same-path", displayName: "Task", repoDisplayName: "Project", repositoryID: repository,
                    displayBranch: "task", state: .closed, isMainCheckout: false, prBadge: nil, stats: nil,
                    attentionText: nil, layout: nil,
                    origin: .init(deviceID: .init(value: host), deviceLabel: host, relayDepth: 0))
            }
        }
        let reports = rows.enumerated().map { index, row in
            let report = stop(Double(index + 100))
            return SidebarActivityItem(id: "legacy-\(index)", projectID: SidebarProjection.projectID(row),
                worktreeID: row.path, paneID: nil, projectName: "Project", worktreeName: "Task", title: "Review",
                occurrence: report.occurrence, isBusy: false, agentStop: report)
        }
        defaults.set(try JSONEncoder().encode(reports), forKey: "test.worktreeReports")
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        for (row, report) in zip(rows, reports) {
            assertEquivalent(navigation, row, defaults)
            #expect(navigation.worktreeContext(row).item.agentStop == report.agentStop)
        }
    }

    private final class ChangeCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private func assertEquivalent(_ navigation: SidebarNavigationState, _ row: WorktreePanes,
                                  _ defaults: UserDefaults, sourceLocation: SourceLocation = #_sourceLocation) {
        let workspace = defaults.data(forKey: "test.attentionWorkspace").flatMap {
            try? JSONDecoder().decode(SidebarAttentionWorkspace.self, from: $0)
        } ?? .init()
        let reports = defaults.data(forKey: "test.worktreeReports").flatMap {
            try? JSONDecoder().decode([SidebarActivityItem].self, from: $0)
        } ?? []
        let reference = SidebarWorktreeContext(worktree: row, retained: workspace.items + reports) { item in
            item.occurrence?.source == .agentStop ? workspace.isDismissed(item) : navigation.hasViewed(item)
        }
        #expect(navigation.worktreeContext(row) == reference, sourceLocation: sourceLocation)
    }

    private func stop(_ time: Double, title: String = "Review", need: String? = "Approve?") -> SidebarAgentStop {
        .init(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: time),
              recap: .init(title: title, completed: "Synthetic change", next: "Inspect", need: need), providerSessionKey: "agent")
    }

    private func row(project: String = "p", path: String = "/wt", id: String = "stable", name: String = "Task",
                     stop: SidebarAgentStop? = nil, progress: [String: Double] = [:],
                     state: WorktreeWireState = .running) -> WorktreePanes {
        .init(path: path, displayName: name, repoDisplayName: "Project", displayBranch: "task", state: state,
              isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
              layout: .leaf(sessionName: "pane", title: "Codex", attentionText: nil, isBusy: true, attentionSource: nil),
              sidebar: .init(id: id, projectID: project, unseenAgentStop: stop, agentProgressTimes: progress))
    }
}
