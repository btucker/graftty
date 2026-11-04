#if canImport(UIKit)
import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite("Mobile worktree reports")
@MainActor
struct MobileAttentionPaneTests {
    /// Pins mobile's per-platform parameters to the shared sidebar row views
    /// (the Mac's are pinned in PaneTitleRowPortsTests).
    @Test("Mobile divergence ahead colour is the 45% sidebar secondary text, or system secondary without a theme")
    func mobileDivergenceAheadColor() {
        #expect(DivergenceGutter.aheadColor(.fallback) == GhosttyThemeColors.fallback.sidebarSecondaryText)
        #expect(DivergenceGutter.aheadColor(nil) == .secondary)
    }

    @Test("@spec IOS-13.11: While a worktree is open on mobile, the application shall show how far it is ahead of and behind its base there, rather than on its list row.")
    func openWorktreeCarriesDivergence() {
        func worktree(_ stats: WorktreeWireStats?) -> WorktreePanes {
            WorktreePanes(path: "/w", displayName: "w", repoDisplayName: "r", displayBranch: "w", state: .running, isMainCheckout: false,
                          prBadge: nil, stats: stats, attentionText: nil, layout: nil)
        }
        func text(_ stats: WorktreeWireStats?) -> String? {
            let row = worktree(stats)
            return IPadWorktreeSubtitle.text(for: row, context: SidebarWorktreeContext(worktree: row))
        }
        #expect(text(WorktreeWireStats(ahead: 3, behind: 1, hasUncommittedChanges: true, baseRef: nil)) == "↑3+ ↓1")
        #expect(text(WorktreeWireStats(ahead: 0, behind: 2, hasUncommittedChanges: false, baseRef: nil)) == "↓2")
        #expect(text(WorktreeWireStats(ahead: 0, behind: 0, hasUncommittedChanges: false, baseRef: nil)) == nil)
    }

    @Test func identityHeaderLeavesNoGapWithoutABadgeOrDivergence() {
        func worktree(_ stats: WorktreeWireStats?) -> WorktreePanes {
            WorktreePanes(path: "/w", displayName: "w", repoDisplayName: "r", displayBranch: "w", state: .running, isMainCheckout: false,
                          prBadge: nil, stats: stats, attentionText: nil, layout: nil)
        }
        let available = CGSize(width: 390, height: 600)
        func height(_ stats: WorktreeWireStats?) -> CGFloat {
            UIHostingController(rootView: MobileWorktreeIdentityHeader(worktree: worktree(stats), purpose: nil, theme: .fallback))
                .sizeThatFits(in: available).height
        }
        let stats = WorktreeWireStats(ahead: 3, behind: 1, hasUncommittedChanges: false, baseRef: nil)
        let gutter = UIHostingController(rootView: DivergenceGutter(stats: stats, theme: .fallback)).sizeThatFits(in: available).height
        // The row's own top padding comes and goes with the row, not just its content.
        #expect(height(stats) - height(nil) >= gutter + 2)
        #expect(height(WorktreeWireStats(ahead: 0, behind: 0, hasUncommittedChanges: false, baseRef: nil)) == height(nil))
    }

    @Test("@spec IOS-9.14: While a mobile worktree identity is displayed at a narrow width, the application shall keep its name on one line and retain space for the information button and its time.", arguments: [320.0, 393.0, 540.0])
    func longNamesDoNotInflateRows(width: Double) {
        func size(name: String) -> CGSize {
            let row = WorktreePanes(path: "/repo/feature", displayName: name, repoDisplayName: "graftty",
                displayBranch: name, state: .closed, isMainCheckout: false,
                prBadge: .init(number: 405, state: .open, checks: .success,
                    url: URL(string: "https://github.com/btucker/graftty/pull/405")!),
                stats: .init(ahead: 12, behind: 25, hasUncommittedChanges: true, baseRef: "main"),
                attentionText: nil, layout: nil,
                sidebar: .init(id: "feature", projectID: "graftty", activityTime: Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate))
            let hosted = UIHostingController(rootView: WorktreeBlock(worktree: row,
                theme: nil, isActive: false, isOpening: false,
                projectColumn: true, context: SidebarWorktreeContext(worktree: row),
                onSelect: {}, onReport: {}))
            return hosted.sizeThatFits(in: CGSize(width: width, height: 600))
        }
        let short = size(name: "feature")
        let long = size(name: "merge-recent-activity-attention-and-unified-worktree-reports")
        #expect(long.width <= width)
        #expect(long.height == short.height)
        #expect(long.height >= 44)
    }

    @Test("@spec IOS-13.12: While a mobile worktree list shows a row, the application shall show its name in its own letter case, followed by its PR number when it has one and its time at the trailing edge.")
    func rowShowsItsNameThenItsPRThenItsTime() async throws {
        let row = WorktreePanes(path: "/repo/Fix-Row", displayName: "Fix-Row", repoDisplayName: "graftty",
            displayBranch: "Fix-Row", state: .running, isMainCheckout: false,
            prBadge: .init(number: 405, state: .open, checks: .success,
                url: URL(string: "https://github.com/btucker/graftty/pull/405")!),
            stats: nil, attentionText: nil, layout: nil)
        let time = Date().addingTimeInterval(-300)
        func labelled(_ time: Date?) async throws -> [String: CGRect] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 100))
            window.rootViewController = UIHostingController(rootView: WorktreeRowContent(worktree: row, theme: nil,
                isActive: false, isOpening: false, attentionCount: 0, time: time)
                .frame(width: 360).accessibilityElement(children: .contain).environment(\.accessibilityEnabled, true))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            var labels: [String: CGRect] = [:]
            for _ in 0..<100 {
                window.rootViewController?.view.layoutIfNeeded()
                labels = [:]
                for object in accessibilityObjects(in: window.rootViewController!.view) {
                    if let label = object.accessibilityLabel { labels[label] = object.accessibilityFrame }
                }
                if labels["Fix-Row"] != nil, time == nil || labels.count > 2 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            return labels
        }
        let labels = try await labelled(time)
        let name = try #require(labels["Fix-Row"])
        let badge = try #require(labels.first { $0.key.contains("405") }?.value)
        let shown = try #require(labels[time.formatted(.relative(presentation: .named))])
        #expect(name.maxX <= badge.minX)
        #expect(badge.maxX <= shown.minX)
        #expect(shown.maxX > 300)
        // IOS-13.8: a row with no known time shows none.
        let timeless = try await labelled(nil)
        #expect(!timeless.keys.contains(time.formatted(.relative(presentation: .named))))
    }

    @Test("@spec IOS-9.13: When the user taps a mobile worktree's information button, the application shall show its report without selecting the worktree or acknowledging its request; the button shall provide a 44-point touch target.")
    func informationButtonOnlyPreviewsReport() {
        let navigation = SidebarNavigationState(prefix: "mobile-info.\(UUID())")
        let context = navigation.worktreeContext(worktree())
        var reportShown = false
        let button = MobileWorktreeReportButton(worktreeName: "push", onReport: { reportShown = true })
        button.activate()
        #expect(reportShown)
        #expect(!navigation.hasViewed(context.item))
        #expect(navigation.selectedProjectID == nil)
        let hosted = UIHostingController(rootView: button)
        let size = hosted.sizeThatFits(in: CGSize(width: 320, height: 640))
        #expect(size.width >= 44 && size.height >= 44)
    }

    @Test("@spec IOS-4.33: When a paired Mac sends a stopped-agent recap, GrafttyMobile shall display its full report in a presentation that fits a compact iPhone width.")
    func recapFitsPhoneReport() {
        let context = SidebarNavigationState(prefix: "mobile-report.\(UUID())").worktreeContext(worktree())
        let controller = UIHostingController(rootView: MobileWorktreeReportContent(context: context,
            onOpen: { true }, onDismiss: {}, onClose: {}))
        let size = controller.sizeThatFits(in: CGSize(width: 320, height: 640))
        #expect(size.width > 0 && size.width <= 320)
        #expect(size.height > 0 && size.height <= 640)
    }

    @Test("@spec LAYOUT-2.141: When a mobile worktree row recognizes a 500ms hold, the application shall show its report without selecting the worktree, acknowledging its request, or firing its terminal tap action.")
    func holdOpensOnlyReport() {
        let navigation = SidebarNavigationState(prefix: "mobile-hold.\(UUID())")
        let context = navigation.worktreeContext(worktree())
        var selected = false
        var reportShown = false
        let target = MobileWorktreeReportTarget(onOpen: {
            selected = true
            navigation.opened(context.item)
        }, onReport: { reportShown = true }) { Text("Worktree") }
        #expect(MobileWorktreeReportTarget<Text>.holdDuration == 0.5)
        target.activate(.first(true))
        #expect(reportShown)
        #expect(!selected)
        #expect(!navigation.hasViewed(context.item))
        target.activate(.second(()))
        #expect(selected)
        #expect(navigation.hasViewed(context.item))
    }

    @Test("@spec IOS-4.36: When a mobile worktree report is viewed, the application shall preserve its pending question until the agent resumes and retain the recap as a previous report afterward.")
    func reportSurvivesViewingAndResume() {
        let navigation = SidebarNavigationState(prefix: "mobile-retained.\(UUID())")
        var row = worktree()
        let pending = navigation.worktreeContext(row)
        #expect(pending.question != nil)
        navigation.opened(pending.item)
        let viewed = navigation.worktreeContext(row)
        #expect(viewed.question == pending.question)
        #expect(viewed.pending.count == pending.pending.count)
        #expect(viewed.item.agentStop?.recap == pending.item.agentStop?.recap)
        row = worktree(progressTimes: ["codex": 101])
        let resumed = navigation.worktreeContext(row)
        #expect(resumed.isRunning)
        #expect(resumed.question == nil)
        #expect(resumed.item.agentStop?.recap != nil)
    }

    @Test("@spec LAYOUT-2.142: When a mobile worktree search matches a retained report field, the application shall include that worktree without changing host-published order.")
    func searchIncludesViewedReportFields() {
        let navigation = SidebarNavigationState(prefix: "mobile-search.\(UUID())")
        let row = worktree()
        navigation.opened(navigation.worktreeContext(row).item)
        for query in ["client integration", "CI passed", "delivery on the phone", "Which device"] {
            #expect(navigation.worktreeContext(row).matches(query: query))
        }
        #expect(!navigation.worktreeContext(row).matches(query: "absent report field"))
    }

    @Test("@spec LAYOUT-2.144: While a mobile pane has a pending report question, the application shall show a compact preview of at most two lines beneath the associated pane, retain the full question for its report and accessibility, and suppress its duplicate status label.")
    func questionPreviewStaysCompact() throws {
        let question = String(repeating: "Which device should receive the test? ", count: 7)
        let context = SidebarWorktreeContext(worktree: worktree(question: question))
        #expect(context.questionPaneID == "session")
        #expect(context.question == question)
        let view = UIHostingController(rootView: SidebarWorktreeQuestion(context: context)
            .environment(\.accessibilityEnabled, true))
        let short = UIHostingController(rootView: SidebarWorktreeQuestion(
            context: SidebarWorktreeContext(worktree: worktree(question: "Proceed?"))))
        let available = CGSize(width: 280, height: 600)
        let size = view.sizeThatFits(in: available)
        #expect(size.width <= available.width)
        let singleLineHeight = short.sizeThatFits(in: available).height
        #expect(size.height > singleLineHeight)
        #expect(size.height <= 2 * singleLineHeight)

        let navigation = SidebarNavigationState(prefix: "mobile-question.\(UUID())")
        func rowHeight(_ context: SidebarWorktreeContext) -> CGFloat {
            UIHostingController(rootView: WorktreeBlock(worktree: context.worktree,
                theme: nil, isActive: false, isOpening: false,
                context: context, onSelect: {}, onReport: {}))
                .sizeThatFits(in: available).height
        }
        navigation.dismissRequest(in: context)
        #expect(rowHeight(context) > rowHeight(navigation.worktreeContext(context.worktree)))

        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = view
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        view.view.layoutIfNeeded()
        #expect(accessibilityObjects(in: view.view).contains { $0.accessibilityLabel == "Needs your input: " + question })
    }

    @Test("@spec PORTS-5.19: While a mobile worktree port row or host browser toolbar is displayed at a compact width, the application shall retain the link and navigation controls while truncating long process and host names.", arguments: [280.0, 320.0, 393.0])
    func browserControlsAndPortsFitCompactWidths(width: Double) throws {
        let processName = String(repeating: "process-", count: 40)
        let toolbar = HostBrowserControls(hostLabel: String(repeating: "Long Mac name ", count: 40),
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {}, onReload: {})
        let ports = SidebarWorktreePorts(ports: [.init(port: 43210, scope: .loopback,
            processName: processName)], onOpen: { _ in })
        let host = UIHostingController(rootView: VStack(spacing: 24) { ports; toolbar }.padding(16)
            .ignoresSafeArea()
            .accessibilityElement(children: .contain)
            .environment(\.accessibilityEnabled, true))
        let size = host.sizeThatFits(in: CGSize(width: width, height: 600))
        #expect(size.width <= width)
        #expect(size.height >= 44 && size.height < 200)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        let objects = accessibilityObjects(in: host.view)
        for label in ["Back", "Forward", "Reload", "Open port 43210, \(processName)"] {
            let control = try #require(objects.first { $0.accessibilityLabel == label },
                "Missing \(label) at \(width) points")
            #expect(control.accessibilityTraits.contains(.button))
            let frame = window.convert(control.accessibilityFrame, from: nil)
            #expect(!frame.isEmpty)
            #expect(window.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                "\(label) frame \(frame) must fit viewport \(window.bounds)")
            #expect(control.accessibilityTraits.contains(.notEnabled) == (label == "Forward"))
        }
    }

    private func accessibilityObjects(in root: NSObject) -> [NSObject] {
        var objects: [NSObject] = [], pending = [root], seen: Set<ObjectIdentifier> = []
        while let object = pending.popLast(), objects.count < 4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            objects.append(object)
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            pending.append(contentsOf: (object.accessibilityElements ?? []).compactMap { $0 as? NSObject })
            pending.append(contentsOf: (object.automationElements ?? []).compactMap { $0 as? NSObject })
            for index in 0..<max(0, min(object.accessibilityElementCount(), 128)) {
                if let child = object.accessibilityElement(at: index) as? NSObject { pending.append(child) }
            }
        }
        return objects
    }

    private func worktree(progressTimes: [String: Double]? = nil,
                          question: String = "Which device should receive the test?") -> WorktreePanes {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 100),
            recap: .init(title: "Paired-device push notifications",
                         context: "The client integration is committed.", completed: "CI passed.",
                         next: "Verify delivery on the phone.", need: question),
            paneTitle: "Verify push delivery")
        return WorktreePanes(path: "/repo/push", displayName: "push", repoDisplayName: "graftty",
            displayBranch: "push", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: .leaf(sessionName: "session", title: "Verify push delivery", attentionText: nil, isBusy: false, attentionSource: nil),
            sidebar: .init(id: "push", projectID: "project", unseenAgentStop: stop, agentProgressTimes: progressTimes))
    }
}
#endif
