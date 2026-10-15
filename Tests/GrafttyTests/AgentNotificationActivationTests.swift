import AppKit
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@MainActor
@Suite("@spec NOTIF-1.11: When the user activates a local agent notification, the application shall retain the request until a window can open its worktree through the normal selection path, restoring terminal surfaces and the originating pane without changing selection or acknowledging attention if the worktree cannot wake.", .serialized)
struct AgentNotificationActivationTests {
    private func payload(path: String = "/repo/task", pane: String? = nil) -> AgentStopNotificationPayload {
        .init(runtime: .codex, worktreePath: path, sessionID: "agent", paneSessionName: pane,
              attentionTimestamp: Date(timeIntervalSinceReferenceDate: 100))
    }

    @Test func queuedClickIsConsumedOnInitialWindowMountAndCanRepeat() async throws {
        let activation = AgentNotificationActivation()
        let click = payload()
        activation.enqueue(click)
        var received: [AgentStopNotificationPayload] = []
        let host = NSHostingView(rootView: Color.clear.modifier(
            AgentNotificationActivationHandler(activation: activation, onActivate: { received.append($0) })))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await waitFor { received.count == 1 }
        #expect(received == [click])
        #expect(activation.pending == nil)

        activation.enqueue(click)
        try await waitFor { received.count == 2 }
        #expect(received == [click, click])
        #expect(activation.pending == nil)
    }

    @Test func newestClickSupersedesOlderClickAndCanOnlyBeClaimedOnce() throws {
        let activation = AgentNotificationActivation()
        let first = payload(path: "/repo/first")
        let latest = payload()
        activation.enqueue(first)
        let oldID = try #require(activation.pending?.id)
        activation.enqueue(latest)
        let currentID = try #require(activation.pending?.id)
        #expect(currentID != oldID)
        #expect(activation.consume(oldID) == nil)
        #expect(activation.pending?.id == currentID)
        #expect(activation.consume(currentID) == latest)
        #expect(activation.consume(currentID) == nil)
        #expect(activation.pending == nil)
    }

    @Test func consumingWindowIsRaisedBeforeSelection() async throws {
        let activation = AgentNotificationActivation()
        let consumer = NotificationActivationTestWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
            styleMask: .titled, backing: .buffered, defer: false)
        let foreground = NotificationActivationTestWindow(
            contentRect: NSRect(x: -10200, y: -10000, width: 100, height: 100),
            styleMask: .titled, backing: .buffered, defer: false)
        consumer.isReleasedWhenClosed = false
        foreground.isReleasedWhenClosed = false
        var received: [AgentStopNotificationPayload] = []
        var raisedBeforeSelection = false
        consumer.contentView = NSHostingView(rootView: Color.clear.modifier(
            AgentNotificationActivationHandler(activation: activation, onActivate: { [weak consumer] payload in
                received.append(payload)
                raisedBeforeSelection = consumer?.activationActions.starts(with: ["deminiaturize", "makeKeyAndOrderFront"]) == true
            })))
        consumer.orderFront(nil)
        foreground.makeKeyAndOrderFront(nil)
        defer { consumer.close(); foreground.close() }
        let foregroundActions = foreground.activationActions

        let click = payload()
        activation.enqueue(click)
        try await waitFor { !received.isEmpty }
        #expect(received == [click])
        #expect(raisedBeforeSelection)
        // Offscreen test windows cannot reliably become key while the test app is inactive.
        // Verify the native activation commands reached only the consuming host, in order.
        #expect(consumer.activationActions.starts(with: ["deminiaturize", "makeKeyAndOrderFront"]))
        #expect(foreground.activationActions == foregroundActions)
        #expect(activation.pending == nil)
    }

    @Test func evictedRunningTargetUsesPaneSelectionWithExistingSessions() {
        let first = PaneSlotID(), agent = PaneSlotID()
        let firstSession = PaneSessionID(), agentSession = PaneSessionID()
        var worktree = WorktreeEntry(path: "/repo/task", branch: "task", state: .running)
        worktree.splitTree = SplitTree(root: .split(.init(direction: .horizontal, ratio: 0.5,
                                                       left: .leaf(first), right: .leaf(agent))))
        worktree.paneSessions = [first: firstSession, agent: agentSession]
        worktree.focusedPaneSlotID = first
        let manager = TerminalManager(socketPath: "/tmp/graftty-notification-activation-test.sock")
        manager.recordPaneSession(firstSession, for: first, worktreePath: worktree.path)
        manager.recordPaneSession(agentSession, for: agent, worktreePath: worktree.path)
        manager.evictSurface(terminalID: first)
        manager.evictSurface(terminalID: agent)
        #expect(manager.handle(for: agent) == nil)
        var opened: [(String, PaneSlotID)] = []

        let succeeded = AgentNotificationActivation.open(
            payload(pane: ZmxLauncher.sessionName(for: agentSession)), worktree: worktree,
            selectWorktree: { _ in Issue.record("Lost the originating pane"); return false },
            selectPane: { path, pane in opened.append((path, pane)); return true })

        #expect(succeeded)
        #expect(opened.count == 1)
        #expect(opened.first?.0 == worktree.path)
        #expect(opened.first?.1 == agent)
        #expect(worktree.paneSessions == [first: firstSession, agent: agentSession])
        #expect(manager.zmxSessionName(for: agent) == ZmxLauncher.sessionName(for: agentSession))
    }

    @Test func failedSelectionDoesNotAcknowledgeOrChangeTheWorktree() {
        var worktree = WorktreeEntry(path: "/repo/task", branch: "task", state: .running)
        let pane = PaneSlotID()
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.setAttention(.init(text: "Still needs input", timestamp: .now), pane: nil)
        let original = worktree
        var attempted = false
        #expect(!AgentNotificationActivation.open(payload(), worktree: worktree,
            selectWorktree: { _ in Issue.record("Expected pane selection"); return false },
            selectPane: { _, _ in attempted = true; return false }))
        #expect(attempted)
        #expect(worktree == original)
    }

    @Test func closedTargetUsesWorktreeSelectionAndMissingTargetDoesNothing() {
        let worktree = WorktreeEntry(path: "/repo/task", branch: "task", state: .closed)
        var opened: [String] = []
        #expect(AgentNotificationActivation.open(payload(), worktree: worktree,
            selectWorktree: { opened.append($0); return true },
            selectPane: { _, _ in Issue.record("Closed target has no pane"); return false }))
        #expect(opened == [worktree.path])
        #expect(!AgentNotificationActivation.open(payload(), worktree: nil,
            selectWorktree: { _ in Issue.record("Selected a missing target"); return true },
            selectPane: { _, _ in Issue.record("Selected a missing pane"); return true }))
    }

    @Test func staleLayoutDoesNotFocusItsObsoletePaneAfterResurrection() {
        var worktree = WorktreeEntry(path: "/repo/task", branch: "task", state: .stale)
        worktree.splitTree = SplitTree(root: .leaf(PaneSlotID()))
        var reopened = false
        #expect(AgentNotificationActivation.open(payload(), worktree: worktree,
            selectWorktree: { _ in reopened = true; return true },
            selectPane: { _, _ in Issue.record("Resurrection replaces the old pane"); return false }))
        #expect(reopened)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<40 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

@MainActor
private final class NotificationActivationTestWindow: NSWindow {
    var activationActions: [String] = []

    override func deminiaturize(_ sender: Any?) {
        activationActions.append("deminiaturize")
        super.deminiaturize(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        activationActions.append("makeKeyAndOrderFront")
        super.makeKeyAndOrderFront(sender)
    }
}
