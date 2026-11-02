import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@MainActor
struct AgentRecoveryTests {
    @Test("@spec AGENT-6.119: When process observation suspends during another session's cleanup, the application shall preserve assignment updates received during that suspension before saving later process observations.")
    func observationPreservesConcurrentCompletion() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let a = PaneSlotID(), b = PaneSlotID(), firstSession = PaneSessionID(), secondSession = PaneSessionID()
        var first = ManagedAgent(name: "Exited", provider: .codex, parent: nil)
        first.paneSlotID = a; first.paneSessionID = firstSession; first.nativeAgentID = "codex-111111111111"
        var second = ManagedAgent(name: "Completing", provider: .codex, parent: nil)
        second.paneSlotID = b; second.paneSessionID = secondSession; second.nativeAgentID = "codex-222222222222"
        platform.state.repos[0].worktrees[0].agents = [first, second]
        platform.state.repos[0].worktrees[0].paneSessions = [a: firstSession, b: secondSession]
        platform.state.repos[0].worktrees[0].splitTree = SplitTree(root: .leaf(a)).inserting(b, at: a, direction: .horizontal)
        platform.liveAgentSessionNames = [ZmxLauncher.sessionName(for: secondSession)]
        let assignment = second.assignmentID
        platform.beforeAgentClose = {
            _ = try? platform.state.repos[0].worktrees[0].agents[1].finish(assignment: assignment, result: "Finished during cleanup")
        }
        await AgentControl.reconcileOutbox(platform: platform)
        let current = platform.state.repos[0].worktrees[0].agents[1]
        #expect(current.status == .awaitingCleanup)
        #expect(current.completion?.result == "Finished during cleanup")
    }

    @Test("@spec AGENT-6.117: If a managed parent closes while a new worktree resolves its base, the application shall reject the child before reserving its destination or starting its launch.")
    func newWorktreeRechecksParentAfterBaseCapture() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var parent = ManagedAgent(name: "Parent", provider: .codex, parent: nil)
        parent.nativeAgentID = "codex-123456789abc"
        parent.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        let completion = try parent.finish(assignment: parent.assignmentID, result: "Done")
        platform.state.repos[0].worktrees[0].agents = [parent]
        var child = ManagedAgent(name: "Child", provider: .codex,
            parent: .init(member: "Parent", worktree: "/repo", runtime: "codex", agentID: parent.nativeAgentID))
        child.parentManagedAgentID = parent.id
        child.paneSlotID = PaneSlotID()
        child.paneSessionID = PaneSessionID()
        let parentID = parent.id
        var closedInsideResolver = false
        platform.worktreeCreations = CLIWorktreeCreationStore(baseResolver: { _, _ in
            let response = await AgentControl.handle(.init(action: .close, callerWorktree: "/repo",
                agentID: parentID, completionID: completion.id), platform: platform)
            guard case .agents(let rows) = response else { throw CocoaError(.fileReadUnknown) }
            closedInsideResolver = rows.first?.agent.status == .closed
            return String(repeating: "a", count: 40)
        })
        var launches = 0
        platform.finishCreation = { _ in launches += 1; return nil }
        let response = await CLIWorktreeCreationRequestHandler.begin(.init(callerWorktree: "/repo",
            worktreeName: "child", branchName: "child", existing: false, base: "main", command: nil,
            agentRuntime: .codex, agentPrompt: "Task", operationID: UUID().uuidString,
            managedAgent: child), platform: platform)
        #expect(closedInsideResolver)
        guard case .error = response else { Issue.record("Child admitted after its parent closed"); return }
        #expect(platform.state.repos[0].worktrees.count == 1)
        #expect(platform.state.repos[0].worktrees[0].agents.count == 1)
        #expect(launches == 0)
        #expect(WorktreeAgentLaunchCommand.recoveryPromptFiles(in: platform.agentPromptDirectory).isEmpty)
    }
    @Test("@spec AGENT-6.115: While draining provider exits, the application shall use the owning host's event directory and retain unknown-agent events and events whose state persistence failed.")
    func lifecycleEventsAreHostScopedAndRetryable() async throws {
        let first = try ControlRequestCoreTests.RecordingPlatform()
        let second = try ControlRequestCoreTests.RecordingPlatform()
        var firstAgent = ManagedAgent(name: "First", provider: .codex, parent: nil)
        firstAgent.paneSessionID = PaneSessionID()
        var secondAgent = ManagedAgent(name: "Second", provider: .codex, parent: nil)
        secondAgent.paneSessionID = PaneSessionID()
        first.state.repos[0].worktrees[0].agents = [firstAgent]
        second.state.repos[0].worktrees[0].agents = [secondAgent]
        let firstHandoff = AgentLifecycleHandoff(directory: first.agentPromptDirectory.appendingPathComponent("lifecycle"))
        let secondHandoff = AgentLifecycleHandoff(directory: second.agentPromptDirectory.appendingPathComponent("lifecycle"))
        let ownEvent = AgentLifecycleEvent(agentID: firstAgent.id, assignmentID: firstAgent.assignmentID,
            sessionID: try #require(firstAgent.paneSessionID), exitCode: 7)
        let foreignEvent = AgentLifecycleEvent(agentID: secondAgent.id, assignmentID: secondAgent.assignmentID,
            sessionID: try #require(secondAgent.paneSessionID), exitCode: 9)
        try firstHandoff.publish(ownEvent)
        try firstHandoff.publish(foreignEvent)
        try secondHandoff.publish(foreignEvent)
        first.saveStateNowError = CocoaError(.fileWriteUnknown)
        await AgentControl.reconcileOutbox(platform: first)
        #expect(first.state.repos[0].worktrees[0].agents[0].status == .running)
        #expect(try firstHandoff.pending().count == 2)
        #expect(try secondHandoff.pending().count == 1)
        first.saveStateNowError = nil
        await AgentControl.reconcileOutbox(platform: first)
        #expect(first.state.repos[0].worktrees[0].agents[0].status == .interrupted)
        #expect(try firstHandoff.pending().map { $0.1.agentID } == [secondAgent.id])
        #expect(second.state.repos[0].worktrees[0].agents[0].status == .running)
        #expect(try secondHandoff.pending().count == 1)
        await AgentControl.reconcileOutbox(platform: second)
        #expect(second.state.repos[0].worktrees[0].agents[0].status == .interrupted)
        #expect(try secondHandoff.pending().isEmpty)
        #expect(try firstHandoff.pending().count == 1)
    }

    @Test("@spec AGENT-6.116: If ordinary managed teardown fails, the application shall preserve the prior process observation and exact session binding together with a retryable interrupted outcome and failure diagnostic.")
    func failedInterruptionDoesNotClaimProcessExit() async throws {
        let observations: [AgentProcessObservation?] = [nil, .reachable, .disconnected]
        for observation in observations {
            let platform = try ControlRequestCoreTests.RecordingPlatform()
            let slot = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
            let session = try #require(platform.state.repos[0].worktrees[0].paneSessions[slot])
            var agent = ManagedAgent(name: "Still live", provider: .codex, parent: nil)
            agent.paneSlotID = slot
            agent.paneSessionID = session
            agent.processObservation = observation
            platform.state.repos[0].worktrees[0].agents = [agent]
            platform.agentCloseFailure = "Injected teardown failure"
            platform.beforeAgentClose = {
                #expect(platform.state.repos[0].worktrees[0].agents[0].processObservation == observation)
                #expect(platform.state.repos[0].worktrees[0].agents[0].completion?.outcome == .interrupted)
            }
            await #expect(throws: (any Error).self) {
                try await AgentControl.interruptSession(path: "/repo", slot: slot, platform: platform)
            }
            let pending = platform.state.repos[0].worktrees[0].agents[0]
            #expect(pending.processObservation == observation)
            #expect(pending.paneSlotID == slot && pending.paneSessionID == session)
            #expect(platform.state.repos[0].worktrees[0].paneSessions[slot] == session)
            #expect(pending.status == .interrupted && pending.requiresAcknowledgment)
            #expect(pending.failure == "Injected teardown failure")
            platform.agentCloseFailure = nil
            platform.beforeAgentClose = nil
            try await AgentControl.interruptSession(path: "/repo", slot: slot, platform: platform)
            let ended = platform.state.repos[0].worktrees[0].agents[0]
            #expect(ended.processObservation == .exited && ended.paneSlotID == nil)
            #expect(ended.completion?.id == pending.completion?.id)
        }
    }
    @Test("@spec AGENT-6.108: When a native provider identity is reused in a new live managed session, the application shall bind new children to the live managed parent rather than its closed historical record.")
    func reusedNativeIdentitySelectsLiveParent() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        var old = ManagedAgent(name: "Old", provider: .codex, parent: nil)
        old.nativeAgentID = "codex-123456789abc"
        let completion = try old.finish(assignment: old.assignmentID, result: "Old result")
        try old.beginClose(completion: completion.id)
        old.didClose()
        var current = ManagedAgent(name: "Current", provider: .codex, parent: nil)
        current.nativeAgentID = old.nativeAgentID
        current.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        platform.state.repos[0].worktrees[0].agents = [old, current]
        let response = await AgentControl.handle(.init(action: .add, callerWorktree: "/repo",
            callerAgentID: current.nativeAgentID, paneSessionName: platform.paneSession,
            name: "Child", worktree: "/repo", provider: .codex), platform: platform)
        guard case .agents(let rows) = response else { Issue.record("Historical identity blocked creation"); return }
        #expect(rows.first?.agent.parentManagedAgentID == current.id)
        let repeatedClose = await AgentControl.handle(.init(action: .close, callerWorktree: "/repo",
            agentID: old.id, completionID: completion.id), platform: platform)
        guard case .agents(let closed) = repeatedClose else { Issue.record("Historical close adopted the live parent's child"); return }
        #expect(closed.first?.agent.status == .closed)
    }
    @Test("@spec AGENT-6.104: When paginating managed agents, the application shall bound each summary page and return a continuation offset without dropping retained records.")
    func summaryPagesRetainEveryIdentity() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let agents = (0..<205).map { ManagedAgent(name: "Agent \($0)", provider: .codex, parent: nil) }
        platform.state.repos[0].worktrees[0].agents = agents
        var request = AgentControlRequest(action: .list, callerWorktree: "/repo")
        request.offset = 100
        guard case .agents(let rows) = await AgentControl.handle(request, platform: platform) else { Issue.record("Expected page"); return }
        #expect(rows.count == 100)
        #expect(rows.last?.nextOffset == 200)
        #expect(rows.map(\.agent.id) == Array(agents[100..<200]).map(\.id))
        #expect(platform.state.repos[0].worktrees[0].agents.count == 205)
    }

    @Test("@spec AGENT-6.105: While a child launch resolves its Git base, the application shall retain its reservation and prevent parent cleanup from orphaning that pending child.")
    func parentCannotCloseDuringBaseResolution() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var parent = ManagedAgent(name: "Parent", provider: .codex, parent: nil)
        parent.nativeAgentID = "codex-123456789abc"
        parent.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        let completion = try parent.finish(assignment: parent.assignmentID, result: "Done")
        platform.state.repos[0].worktrees[0].agents = [parent]
        let parentID = parent.id
        var resolverRan = false
        platform.worktreeCreations = CLIWorktreeCreationStore(baseResolver: { _, _ in
            resolverRan = true
            #expect(platform.state.repos[0].worktrees[0].agents.contains {
                $0.parentManagedAgentID == parentID && $0.status == .starting
            })
            let response = await AgentControl.handle(.init(action: .close, callerWorktree: "/repo",
                agentID: parentID, completionID: completion.id), platform: platform)
            guard case .error = response else { throw CocoaError(.fileReadUnknown) }
            return String(repeating: "a", count: 40)
        })
        let response = await AgentControl.handle(.init(action: .add, callerWorktree: "/repo",
            callerAgentID: "codex-123456789abc", name: "child", provider: .codex, base: "main"), platform: platform)
        #expect(resolverRan)
        guard case .agents(let rows) = response else { Issue.record("New-worktree child was not admitted"); return }
        #expect(rows.first?.agent.parentManagedAgentID == parentID)
        #expect(platform.state.repos[0].worktrees[0].agents.first?.status == .awaitingCleanup)
        #expect(platform.closedAgentSlots.isEmpty)

    }
    @Test("@spec AGENT-6.103: If a delayed provider exit predates a replacement native session, then the application shall preserve the replacement's running assignment.")
    func delayedExitDoesNotInterruptReplacement() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Replacement", provider: .codex, parent: nil)
        agent.paneSessionID = PaneSessionID()
        var event = AgentLifecycleEvent(agentID: agent.id, assignmentID: agent.assignmentID,
            sessionID: try #require(agent.paneSessionID), exitCode: 0)
        event.recordedAt = Date(timeIntervalSince1970: 10)
        agent.nativeBindingDate = Date(timeIntervalSince1970: 20)
        platform.state.repos[0].worktrees[0].agents = [agent]
        let handoff = AgentLifecycleHandoff(directory: platform.agentPromptDirectory.appendingPathComponent("lifecycle"))
        try handoff.publish(event)
        await AgentControl.reconcileOutbox(platform: platform)
        #expect(platform.state.repos[0].worktrees[0].agents[0].status == .running)
        #expect(platform.state.repos[0].worktrees[0].agents[0].completion == nil)
    }
    @Test("@spec AGENT-6.101: When a provider exits after assignment resume, the application shall apply the exact launch-session exit to its current assignment while preserving the earlier completed result.")
    func providerExitAfterResumeInterruptsCurrentAssignment() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Child", provider: .codex, parent: nil)
        agent.paneSessionID = PaneSessionID()
        let launchAssignment = agent.assignmentID
        let first = try agent.finish(assignment: agent.assignmentID, result: "First pass")
        try agent.resume()
        platform.state.repos[0].worktrees[0].agents = [agent]
        let handoff = AgentLifecycleHandoff(directory: platform.agentPromptDirectory.appendingPathComponent("lifecycle"))
        try handoff.publish(.init(agentID: agent.id, assignmentID: launchAssignment,
            sessionID: #require(agent.paneSessionID), exitCode: 7))
        await AgentControl.reconcileOutbox(platform: platform)
        let current = platform.state.repos[0].worktrees[0].agents[0]
        #expect(current.status == .interrupted)
        #expect(current.completion?.assignmentID == agent.assignmentID)
        #expect(current.results.first == first)
        #expect(try handoff.pending().isEmpty)
    }
    @Test("@spec AGENT-6.91: When a parent has begun cleanup, the application shall reject new children before reserving or launching them.")
    func closingParentRejectsNewChildren() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        platform.controlCapabilities.insert(.paneAgent)
        var parent = ManagedAgent(name: "Parent", provider: .codex, parent: nil)
        parent.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        parent.nativeAgentID = "codex-123456789abc"
        let completion = try parent.finish(assignment: parent.assignmentID, result: "Done")
        platform.state.repos[0].worktrees[0].agents = [parent]
        let parentID = parent.id
        platform.beforeAgentClose = {
            let response = await AgentControl.handle(.init(action: .add, callerWorktree: "/repo",
                callerAgentID: "codex-123456789abc", paneSessionName: platform.paneSession,
                name: "Late child", worktree: "/repo", provider: .codex), platform: platform)
            guard case .error = response else { Issue.record("Closing parent created a child"); return }
        }
        _ = await AgentControl.handle(.init(action: .close, callerWorktree: "/repo", agentID: parentID,
            completionID: completion.id), platform: platform)
        #expect(platform.state.repos[0].worktrees[0].agents.count == 1)
    }

    @Test("@spec AGENT-6.92: If a parent endpoint changes while completion delivery is suspended, then the application shall not apply the old destination's delivery receipt to the new destination.")
    func oldParentReceiptCannotAcknowledgeNewParent() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var child = ManagedAgent(name: "Child", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: "codex-123456789abc"))
        try child.finish(assignment: child.assignmentID, result: "Done")
        platform.state.repos[0].worktrees[0].agents = [child]
        platform.beforeCompletionAppend = {
            platform.state.repos[0].worktrees[0].agents[0].parent = .init(member: "main", worktree: "/repo",
                runtime: "codex", agentID: "codex-abcdef123456")
        }
        try await AgentControl.reconcileCompletions(repoIndex: 0, platform: platform)
        #expect(platform.state.repos[0].worktrees[0].agents[0].deliveredCompletionID == nil)
    }

    @Test("@spec AGENT-6.93: When host delivery maintenance runs after restart, the application shall deliver saved pending outcomes without requiring another lifecycle command and continue past a failing outbox item.")
    func autonomousOutboxRecoversAndIsolatesFailures() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var child = ManagedAgent(name: "Child", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: "codex-123456789abc"))
        try child.finish(assignment: child.assignmentID, result: "Done")
        var other = ManagedAgent(name: "Other", provider: .claude, parent: child.parent)
        try other.finish(assignment: other.assignmentID, result: "Also done")
        platform.state.repos[0].worktrees[0].agents = [child, other]
        var calls = 0
        platform.beforeCompletionAppend = {
            calls += 1
            if calls == 1 { throw CocoaError(.fileWriteUnknown) }
        }
        await AgentControl.reconcileOutbox(platform: platform)
        #expect(platform.state.repos[0].worktrees[0].agents[0].deliveredCompletionID == nil)
        #expect(platform.state.repos[0].worktrees[0].agents[1].deliveredCompletionID == other.completion?.id)
        await AgentControl.reconcileOutbox(platform: platform)
        #expect(try platform.teamInbox.messages(teamID: "/repo").count == 2)
    }

    @Test("@spec AGENT-6.86: When an unfinished provider exits, the application shall retain an interrupted outcome for exact parent acknowledgment without claiming successful completion.")
    func interruptedAssignmentRequiresAcknowledgment() throws {
        var agent = ManagedAgent(name: "Child", provider: .codex, parent: nil)
        agent.sessionEnded(reason: "Provider exited with status 127")
        #expect(agent.status == .interrupted)
        #expect(agent.processObservation == .exited)
        let outcome = try #require(agent.completion)
        #expect(outcome.outcome == .interrupted)
        #expect(throws: ManagedAgent.LifecycleError.invalidState) { try agent.resume() }
        try agent.beginClose(completion: outcome.id)
        agent.didClose()
        #expect(agent.status == .closed)
        #expect(agent.results == [outcome])
    }

    @Test("@spec AGENT-6.87: When a provider exits after explicitly finishing, the application shall preserve the completed result and reject resume of the exited process.")
    func exitPreservesFinishedResult() throws {
        var agent = ManagedAgent(name: "Child", provider: .codex, parent: nil)
        let result = try agent.finish(assignment: agent.assignmentID, result: "Done")
        agent.sessionEnded(reason: "Terminal closed")
        #expect(agent.completion == result)
        #expect(agent.status == .awaitingCleanup)
        #expect(throws: ManagedAgent.LifecycleError.invalidState) { try agent.resume() }
    }

    @Test("@spec AGENT-6.83: When listing managed agents, the application shall return bounded summaries without discarding stored results, prompts, or transcripts.")
    func listDoesNotShipArchives() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Review", provider: .codex, parent: nil)
        agent.transcript = String(repeating: "transcript", count: 10_000)
        agent.initialPrompt = String(repeating: "task", count: 10_000)
        try agent.finish(assignment: agent.assignmentID, result: String(repeating: "result", count: 10_000))
        platform.state.repos[0].worktrees[0].agents = [agent]
        let response = await AgentControl.handle(.init(action: .list, callerWorktree: "/repo"), platform: platform)
        guard case .agents(let rows) = response else { Issue.record("Expected summaries"); return }
        #expect(rows.first?.agent.transcript == nil)
        #expect(rows.first?.agent.initialPrompt == nil)
        #expect((rows.first?.agent.completion?.result.utf8.count ?? 0) <= 1024)
        #expect(platform.state.repos[0].worktrees[0].agents[0] == agent)
    }

    @Test("@spec AGENT-6.84: If one completion inbox is unavailable, then the application shall still allow lifecycle inspection and cleanup of other agents.")
    func unreadableInboxDoesNotBlockList() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Review", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: "codex-123456789abc"))
        try agent.finish(assignment: agent.assignmentID, result: "Done")
        platform.state.repos[0].worktrees[0].agents = [agent]
        try FileManager.default.createDirectory(at: platform.root, withIntermediateDirectories: true)
        try Data().write(to: platform.root.appendingPathComponent("inbox"))
        let response = await AgentControl.handle(.init(action: .list, callerWorktree: "/repo"), platform: platform)
        guard case .agents = response else { Issue.record("Outbox failure blocked inspection: \(response)"); return }
    }

    @Test("@spec AGENT-6.85: When a parent recovers with an already-persisted native identity, the application shall repair children that still reference its previous native identity.")
    func partialParentRebindRepairsOnRetry() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var parent = ManagedAgent(name: "Parent", provider: .codex, parent: nil)
        parent.paneSlotID = platform.state.repos[0].worktrees[0].splitTree.allLeaves.first
        parent.nativeAgentID = "codex-abcdef123456"
        var child = ManagedAgent(name: "Child", provider: .codex,
            parent: .init(member: "main", worktree: "/repo", runtime: "codex", agentID: "codex-123456789abc"))
        child.parentManagedAgentID = parent.id
        platform.state.repos[0].worktrees[0].agents = [parent, child]
        _ = try await AgentControl.sessionContext(path: "/repo", agentID: parent.nativeAgentID,
            paneSessionName: platform.paneSession, provider: .codex, platform: platform)
        #expect(platform.state.repos[0].worktrees[0].agents[1].parent?.agentID == parent.nativeAgentID)
    }

    @Test("@spec AGENT-6.88: When requesting an agent by exact ID, the application shall provide bounded detail chunks from one immutable snapshot even when the record changes between requests.")
    func detailChunksRetainFullArchive() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Archive", provider: .codex, parent: nil)
        agent.transcript = String(repeating: "🦊", count: 40_000)
        try agent.finish(assignment: agent.assignmentID, result: "Complete")
        platform.state.repos[0].worktrees[0].agents = [agent]
        var offset = 0
        var data = Data()
        var token: UUID?
        repeat {
            var request = AgentControlRequest(action: .show, callerWorktree: "/repo", agentID: agent.id)
            request.offset = offset
            request.detailToken = token
            guard case .agents(let rows) = await AgentControl.handle(request, platform: platform), let row = rows.first,
                  let chunk = row.detail else { Issue.record("Missing detail"); return }
            #expect(chunk.count <= 64 * 1024)
            data.append(chunk)
            let returnedToken = try #require(row.detailToken)
            if let token { #expect(returnedToken == token) }
            token = returnedToken
            if offset == 0 {
                platform.state.repos[0].worktrees[0].agents[0].name = String(repeating: "Changed during read", count: 100)
                platform.state.repos[0].worktrees[0].agents[0].transcript = "An entirely different transcript"
                try platform.state.repos[0].worktrees[0].agents[0].resume()
            }
            guard let next = row.nextOffset else { break }
            #expect(next > offset)
            offset = next
        } while true
        #expect(try JSONDecoder().decode(ManagedAgent.self, from: data) == agent)
        #expect(platform.state.repos[0].worktrees[0].agents[0].assignmentID != agent.assignmentID)
    }

    @Test("@spec AGENT-6.89: While publishing worktree snapshots, the application shall bound current and previous agent result previews while preserving full stored history.")
    func snapshotResultsHaveWorktreeBudget() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        for _ in 0..<80 {
            var agent = ManagedAgent(name: "Archive", provider: .codex, parent: nil)
            try agent.finish(assignment: agent.assignmentID, result: String(repeating: "🦊", count: 2_000))
            platform.state.repos[0].worktrees[0].agents.append(agent)
        }
        let repo = platform.state.repos[0]
        let row = WorktreePanes(entry: repo.worktrees[0], repo: repo,
            inputs: .init(origin: nil, projectID: "repo", displayName: "main"))
        let bytes = (row.agents ?? []).reduce(0) { $0 + ($1.result?.utf8.count ?? 0) + ($1.previousResults ?? []).reduce(0) { $0 + $1.utf8.count } }
        #expect(bytes <= 32 * 1024)
        #expect(platform.state.repos[0].worktrees[0].agents[0].completion?.result.utf8.count == 8_000)
    }

    @Test("@spec AGENT-6.90: When a managed session ends through ordinary pane controls, the application shall preserve an interrupted result until its parent explicitly acknowledges it.")
    func ordinarySessionEndCanBeAcknowledged() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        var agent = ManagedAgent(name: "Child", provider: .codex, parent: nil)
        let slot = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        agent.paneSlotID = slot
        platform.state.repos[0].worktrees[0].agents = [agent]
        try AgentControl.sessionEnded(path: "/repo", slot: slot, reason: "Closed by user", platform: platform)
        let ended = platform.state.repos[0].worktrees[0].agents[0]
        #expect(ended.status == .interrupted)
        let completion = try #require(ended.completion)
        _ = await AgentControl.handle(.init(action: .close, callerWorktree: "/repo", agentID: agent.id,
            completionID: completion.id), platform: platform)
        #expect(platform.state.repos[0].worktrees[0].agents[0].status == .closed)
    }
}
