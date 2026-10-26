import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

private final class PresenceReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func recordRead() { lock.withLock { reads += 1 } }
    var count: Int { lock.withLock { reads } }
}

@MainActor
private final class PresenceListPlatform: ControlPlatform {
    let root: URL
    var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [
        WorktreeEntry(path: "/repo", branch: "main", state: .running),
    ])])
    let teamInbox: TeamInbox
    let teamEventDispatcher: TeamEventDispatcher
    let teamPresence: TeamPresenceStorage
    let attentionRecaps = AttentionRecapCoordinator()
    var instructionsDirectory: URL { root }
    var remoteTeamRouting: (any ControlRemoteTeamRouting)? { nil }
    var controlCapabilities: Set<ControlCapability> { [] }
    var worktreeCreation: any CLIWorktreeCreationPlatform { fatalError("not used by member listing") }
    var worktreeRemoval: any CLIWorktreeRemovalPlatform { fatalError("not used by member listing") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("team-members-off-main-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        teamInbox = TeamInbox(rootDirectory: root.appendingPathComponent("inbox"))
        teamEventDispatcher = TeamEventDispatcher(inbox: teamInbox, preferencesProvider: { TeamEventRoutingPreferences() },
                                                  templateProvider: { "" })
        teamPresence = TeamPresenceStorage(rootDirectory: root.appendingPathComponent("presence"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func stateDidChange() throws { Issue.record("listing must not mutate state") }
    func providerActivity(path: String, paneSessionName: String?, sessionID: String?, activity: ProviderSleepActivity,
                          runtime: TeamHookRuntime) {}
    func recordHookLiveness(runtime: TeamHookRuntime, event: TeamHookEvent, sessionID: String?, paneSessionName: String,
                            attentionReason: AgentHookAttentionReason?) {}
    func instructionsDefaultBranch(repoPath: String, hint: String?) -> String? { hint }
    func paneTitle(for slot: PaneSlotID, in worktree: WorktreeEntry) -> String? { nil }
    func postAgentNotification(_ content: AgentStopNotificationContent, worktreePath: String) {}
    func hookDeliveryPolicy(presence: [TeamPresenceRecord]) -> TeamHookDeliveryPolicy { TeamHookDeliveryPolicy() }
    func handlePlatformRequest(_ message: NotificationMessage) async -> ResponseMessage? {
        Issue.record("listing must use the shared core")
        return nil
    }
}

@Suite("@spec ATTN-2.28: When a control-socket request lists team members or teams, the application shall read and decode presence files off the main thread while preserving member responses and request errors.")
@MainActor
struct TeamMembersOffMainTests {
    @Test(arguments: [false, true])
    func presenceFilesAreDecodedOffMain(legacyList: Bool) async throws {
        let platform = try PresenceListPlatform()
        defer { platform.cleanUp() }
        let record = TeamPresenceRecord(teamID: "/repo", worktree: "/repo", runtime: .codex,
            paneSessionName: "pane", pid: ProcessInfo.processInfo.processIdentifier,
            registeredAt: Date(timeIntervalSince1970: 100), runtimeSessionID: "test-session")
        try platform.teamPresence.write(record)
        let request: NotificationMessage = legacyList ? .teamList(callerWorktree: "/repo")
            : .teamMembers(callerWorktree: "/repo", worktree: nil, repo: nil)
        let probe = PresenceReadProbe()
        let response = await ControlRequestCore.$presenceRecordsReader.withValue({ storage in
            probe.recordRead()
            #expect(!Thread.isMainThread, "presence read/decode must not block the main thread")
            let decoded = try storage.listAll()
            #expect(decoded == [record])
            return decoded
        }) {
            await ControlRequestCore.handleRequest(request, platform: platform)
        }
        #expect(probe.count == 1, "the thread assertion must observe the actual read")
        guard case .teamList(let name, let members) = response else {
            Issue.record("unexpected response: \(String(describing: response))")
            return
        }
        #expect(name == "repo")
        #expect(members.count == 1)
        #expect(members.first?.worktreePath == "/repo")
        #expect(members.first?.agents.map(\.id) == [TeamAgentIdentity(runtime: .codex, nativeSessionID: "test-session").rawValue])
    }

    @Test(arguments: [false, true])
    func unknownCallerStillReturnsItsError(legacyList: Bool) async throws {
        let platform = try PresenceListPlatform()
        defer { platform.cleanUp() }
        let request: NotificationMessage = legacyList ? .teamList(callerWorktree: "/unknown")
            : .teamMembers(callerWorktree: "/unknown", worktree: nil, repo: nil)
        let response = await ControlRequestCore.$presenceRecordsReader.withValue({ _ in
            Issue.record("invalid scope must fail before reading presence")
            return []
        }) {
            await ControlRequestCore.handleRequest(request, platform: platform)
        }
        #expect(response == .error(TeamInboxRequestError.callerNotTracked.description))
    }
}
