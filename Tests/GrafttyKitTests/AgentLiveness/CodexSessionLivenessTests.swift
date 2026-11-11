import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec AGENT-2.10: While a registered Codex session has a live app-server and an observed active thread, the application shall include its pane in sidebar working activity even when provider hooks are absent, and shall discard polled activity when the provider no longer confirms it.")
struct CodexSessionLivenessTests {
    actor Client: CodexAppServerClienting {
        var queried: [String] = []
        func turnLiveness(binaryPath: String, socketPath: String, expectedCWD: String,
                          target: CodexAppServerTarget) async -> AgentLiveness? {
            queried.append(target.threadID)
            return target.threadID == "busy" ? .busy : .idle
        }
        func deliver(binaryPath: String, socketPath: String, expectedCWD: String,
                     message: String) async throws -> CodexAppServerDeliveryResult {
            Issue.record("Liveness polling must only read provider state")
            throw CancellationError()
        }
    }

    private func record(_ thread: String?, pane: String, start: Int64? = 100) -> CodexAppServerSessionRecord {
        .init(teamID: "/repo", worktree: "/repo/task", paneSessionName: pane,
              socketPath: "/socket", realBinaryPath: "/codex", appServerPID: 1,
              appServerProcessStartTimeMicroseconds: start, registeredAt: Date(), threadID: thread)
    }

    @Test func queriesOnlyLiveBoundSessions() async {
        let client = Client()
        let records = [record("busy", pane: "active"), record("idle", pane: "idle"),
                       record("busy", pane: "reused-pid", start: 99),
                       record("busy", pane: "unverified", start: nil),
                       record(nil, pane: "unbound")]
        let result = await CodexSessionLiveness.poll(records: records, client: client,
                                                    processStartTime: { _ in 100 })
        #expect(result == ["active": ["codex:busy": .busy], "idle": ["codex:idle": .idle]])
        #expect(Set(await client.queried) == ["busy", "idle"])
        #expect(await CodexSessionLiveness.poll(records: records, client: client,
                                              processStartTime: { _ in nil }).isEmpty)
    }
}
