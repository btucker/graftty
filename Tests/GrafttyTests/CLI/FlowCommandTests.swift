import Foundation
import Testing
@testable import GrafttyCLI
@testable import GrafttyKit

@Suite("Flow command dispatcher")
struct FlowCommandTests {
    @Test("flow status sends request and prints status line")
    func status() throws {
        let transport = FlowCommandTransportStub(.flowStatus(FlowStatus(enabled: true, running: false, message: "Needs start")))
        let stdout = FlowCommandTextSink()
        let stderr = FlowCommandTextSink()
        let exit = FlowCommandDispatcher(
            transport: transport,
            stdin: { "" },
            stdout: stdout,
            stderr: stderr
        ).status()

        #expect(exit == 0)
        #expect(transport.messages == [.flowStatus])
        #expect(stdout.text == "enabled=true running=false promptMode=unavailable message=Needs start\n")
        #expect(stderr.text.isEmpty)
    }

    @Test("flow context sends request and prints JSON")
    func context() throws {
        let envelope = FlowContextEnvelope(generatedAt: Date(timeIntervalSince1970: 1), worktrees: [])
        let transport = FlowCommandTransportStub(.flowContext(envelope))
        let stdout = FlowCommandTextSink()
        let exit = FlowCommandDispatcher(
            transport: transport,
            stdin: { "" },
            stdout: stdout,
            stderr: FlowCommandTextSink()
        ).context()

        #expect(exit == 0)
        #expect(transport.messages == [.flowContext])
        #expect(stdout.text == (try FlowCLIOutput.contextJSON(envelope)) + "\n")
    }

    @Test("flow recommend sends request and prints JSON")
    func recommend() throws {
        let envelope = recommendation()
        let transport = FlowCommandTransportStub(.flowRecommendation(envelope))
        let stdout = FlowCommandTextSink()
        let exit = FlowCommandDispatcher(
            transport: transport,
            stdin: { "" },
            stdout: stdout,
            stderr: FlowCommandTextSink()
        ).recommend()

        #expect(exit == 0)
        #expect(transport.messages == [.flowRecommend])
        #expect(stdout.text == (try FlowCLIOutput.recommendationJSON(envelope)) + "\n")
    }

    @Test("flow snooze defaults to manual refresh")
    func snooze() throws {
        let transport = FlowCommandTransportStub(.ok)
        let exit = FlowCommandDispatcher(
            transport: transport,
            stdin: { "" },
            stdout: FlowCommandTextSink(),
            stderr: FlowCommandTextSink()
        ).snooze(worktreeRef: "repo:feature", reason: "Later")

        #expect(exit == 0)
        #expect(transport.messages == [
            .flowSnooze(worktreeRef: "repo:feature", until: .manualRefresh, reason: "Later")
        ])
    }

    @Test("flow snooze accepts explicit hold-until")
    func snoozeExplicitUntil() throws {
        let transport = FlowCommandTransportStub(.ok)
        let exit = FlowCommandDispatcher(
            transport: transport,
            stdin: { "" },
            stdout: FlowCommandTextSink(),
            stderr: FlowCommandTextSink()
        ).snooze(worktreeRef: "repo:feature", until: .nextFocusBreak, reason: nil)

        #expect(exit == 0)
        #expect(transport.messages == [
            .flowSnooze(worktreeRef: "repo:feature", until: .nextFocusBreak, reason: nil)
        ])
    }

    @Test("flow note --stdin reads stdin and sends note")
    func noteFromStdin() throws {
        let transport = FlowCommandTransportStub(.ok)
        let exit = FlowCommandDispatcher(
            transport: transport,
            stdin: { "status note\n" },
            stdout: FlowCommandTextSink(),
            stderr: FlowCommandTextSink()
        ).note(worktreeRef: "repo:feature")

        #expect(exit == 0)
        #expect(transport.messages == [.flowNote(worktreeRef: "repo:feature", body: "status note\n")])
    }

    @Test("flow summary --stdin decodes matching summary and rejects mismatch")
    func summaryFromStdin() throws {
        let matching = FlowWorktreeSummary(
            worktreeRef: "repo:feature",
            updatedAt: Date(timeIntervalSince1970: 1),
            summary: "Done",
            nextAction: "Ship",
            needsHuman: false
        )
        let transport = FlowCommandTransportStub(.ok)
        let stdout = FlowCommandTextSink()
        let stderr = FlowCommandTextSink()
        let dispatcher = FlowCommandDispatcher(
            transport: transport,
            stdin: { try String(data: JSONEncoder.flowState.encode(matching), encoding: .utf8) ?? "" },
            stdout: stdout,
            stderr: stderr
        )

        #expect(dispatcher.summary(worktreeRef: "repo:feature") == 0)
        #expect(transport.messages == [.flowSummary(matching)])
        #expect(stdout.text.isEmpty)
        #expect(stderr.text.isEmpty)

        let mismatched = FlowWorktreeSummary(
            worktreeRef: "repo:other",
            updatedAt: Date(timeIntervalSince1970: 1),
            summary: "Done"
        )
        let mismatchStderr = FlowCommandTextSink()
        let mismatchExit = FlowCommandDispatcher(
            transport: FlowCommandTransportStub(.ok),
            stdin: { try String(data: JSONEncoder.flowState.encode(mismatched), encoding: .utf8) ?? "" },
            stdout: FlowCommandTextSink(),
            stderr: mismatchStderr
        ).summary(worktreeRef: "repo:feature")

        #expect(mismatchExit == 1)
        #expect(mismatchStderr.text.contains("summary worktreeRef 'repo:other' does not match argument 'repo:feature'"))
    }

    @Test("flow summary reports invalid JSON separately from stdin read failure")
    func invalidSummaryJSON() throws {
        let stderr = FlowCommandTextSink()
        let exit = FlowCommandDispatcher(
            transport: FlowCommandTransportStub(.ok),
            stdin: { "not json" },
            stdout: FlowCommandTextSink(),
            stderr: stderr
        ).summary(worktreeRef: "repo:feature")

        #expect(exit == 1)
        #expect(stderr.text.contains("invalid summary JSON"))
    }

    @Test("flow publish --stdin sends raw stdin without local decoding")
    func publishFromStdin() throws {
        let raw = "{\"schemaVersion\":1,\"primary\":{\"intent\":\"bad\"}}\n"
        let transport = FlowCommandTransportStub(.ok)
        let exit = FlowCommandDispatcher(
            transport: transport,
            stdin: { raw },
            stdout: FlowCommandTextSink(),
            stderr: FlowCommandTextSink()
        ).publish()

        #expect(exit == 0)
        #expect(transport.messages == [.flowPublish(rawJSON: raw)])
    }

    @Test("flow request-status sends explicit flag")
    func requestStatus() throws {
        let transport = FlowCommandTransportStub(.ok, .ok)
        let dispatcher = FlowCommandDispatcher(
            transport: transport,
            stdin: { "" },
            stdout: FlowCommandTextSink(),
            stderr: FlowCommandTextSink()
        )

        #expect(dispatcher.requestStatus(worktreeRef: "repo:feature", explicit: false) == 0)
        #expect(dispatcher.requestStatus(worktreeRef: "repo:feature", explicit: true) == 0)
        #expect(transport.messages == [
            .flowRequestStatus(worktreeRef: "repo:feature", explicit: false),
            .flowRequestStatus(worktreeRef: "repo:feature", explicit: true),
        ])
    }

    private func recommendation() -> FlowRecommendationEnvelope {
        FlowRecommendationEnvelope(
            generatedAt: Date(timeIntervalSince1970: 1),
            primary: FlowPrimaryRecommendation(
                worktreeRef: "repo:feature",
                intent: .stay,
                title: "Stay",
                reason: "Because",
                confidence: .medium
            )
        )
    }
}

private final class FlowCommandTransportStub: SocketTransport, @unchecked Sendable {
    private var responses: [ResponseMessage]
    private(set) var messages: [NotificationMessage] = []

    init(_ responses: ResponseMessage...) {
        self.responses = responses
    }

    func send(_ message: NotificationMessage) -> ResponseMessage {
        messages.append(message)
        guard !responses.isEmpty else {
            return .error("missing stub response")
        }
        return responses.removeFirst()
    }
}

private final class FlowCommandTextSink: TextSink, @unchecked Sendable {
    private(set) var text = ""

    func write(_ text: String) {
        self.text += text
    }
}
