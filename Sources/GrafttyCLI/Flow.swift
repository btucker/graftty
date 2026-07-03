import ArgumentParser
import Foundation
import GrafttyKit

struct Flow: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and update Flow State",
        subcommands: [
            FlowStatusCommand.self,
            FlowContextCommand.self,
            FlowRecommendCommand.self,
            FlowSnoozeCommand.self,
            FlowNoteCommand.self,
            FlowSummaryCommand.self,
            FlowPublishCommand.self,
            FlowRequestStatusCommand.self,
        ]
    )
}

struct FlowStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Print Flow State status")

    func run() throws {
        let exit = FlowCommandDispatcher.live.status()
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct FlowContextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "context", abstract: "Print Flow State context JSON")

    func run() throws {
        let exit = FlowCommandDispatcher.live.context()
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct FlowRecommendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recommend", abstract: "Print latest Flow State recommendation JSON")

    func run() throws {
        let exit = FlowCommandDispatcher.live.recommend()
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct FlowSnoozeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "snooze", abstract: "Snooze a Flow State worktree")

    @Argument(help: "Flow State worktree reference")
    var worktreeRef: String

    @Option(name: .long, help: "Reason for snoozing this worktree")
    var reason: String?

    @Option(name: .long, help: "Hold until: next_focus_break, manual_refresh, or ISO8601 timestamp")
    var until: String = "manual_refresh"

    func validate() throws {
        _ = try FlowHoldUntilCLI.parse(until)
    }

    func run() throws {
        let exit = FlowCommandDispatcher.live.snooze(
            worktreeRef: worktreeRef,
            until: try FlowHoldUntilCLI.parse(until),
            reason: reason
        )
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct FlowNoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "note", abstract: "Attach a Flow State note from standard input")

    @Argument(help: "Flow State worktree reference")
    var worktreeRef: String

    @Flag(name: .long, help: "Read note body from standard input")
    var stdin: Bool = false

    func validate() throws {
        guard stdin else { throw ValidationError("note requires --stdin") }
    }

    func run() throws {
        let exit = FlowCommandDispatcher.live.note(worktreeRef: worktreeRef)
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct FlowSummaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "summary", abstract: "Update a Flow State worktree summary from JSON on standard input")

    @Argument(help: "Flow State worktree reference")
    var worktreeRef: String

    @Flag(name: .long, help: "Read summary JSON from standard input")
    var stdin: Bool = false

    func validate() throws {
        guard stdin else { throw ValidationError("summary requires --stdin") }
    }

    func run() throws {
        let exit = FlowCommandDispatcher.live.summary(worktreeRef: worktreeRef)
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct FlowPublishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "publish", abstract: "Publish raw Flow State recommendation JSON from standard input")

    @Flag(name: .long, help: "Read raw publish JSON from standard input")
    var stdin: Bool = false

    func validate() throws {
        guard stdin else { throw ValidationError("publish requires --stdin") }
    }

    func run() throws {
        let exit = FlowCommandDispatcher.live.publish()
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct FlowRequestStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "request-status", abstract: "Request a Flow State status update for a worktree")

    @Argument(help: "Flow State worktree reference")
    var worktreeRef: String

    @Flag(name: .long, help: "Mark this status request as explicit user intent")
    var explicit: Bool = false

    func run() throws {
        let exit = FlowCommandDispatcher.live.requestStatus(worktreeRef: worktreeRef, explicit: explicit)
        if exit != 0 { throw ExitCode(exit) }
    }
}

struct FlowCommandDispatcher {
    var transport: any SocketTransport
    var stdin: () throws -> String
    var stdout: any TextSink
    var stderr: any TextSink

    static var live: FlowCommandDispatcher {
        FlowCommandDispatcher(
            transport: SocketTransportClient.shared,
            stdin: FlowStdinInput.readAll,
            stdout: StandardOutSink(),
            stderr: StandardErrSink()
        )
    }

    func status() -> Int32 {
        let response = transport.send(.flowStatus)
        switch response {
        case .flowStatus(let status):
            stdout.write(FlowCLIOutput.statusLine(status) + "\n")
            return 0
        default:
            return handleUnexpectedResponse(response, expected: "flow_status")
        }
    }

    func context() -> Int32 {
        switch transport.send(.flowContext) {
        case .flowContext(let context):
            do {
                stdout.write(try FlowCLIOutput.contextJSON(context) + "\n")
                return 0
            } catch {
                emit("failed to encode Flow State context: \(error)", to: stderr)
                return 1
            }
        case .error(let msg):
            emit(msg, to: stderr)
            return 1
        default:
            emit("unexpected response for flow context", to: stderr)
            return 1
        }
    }

    func recommend() -> Int32 {
        switch transport.send(.flowRecommend) {
        case .flowRecommendation(let recommendation):
            do {
                stdout.write(try FlowCLIOutput.recommendationJSON(recommendation) + "\n")
                return 0
            } catch {
                emit("failed to encode Flow State recommendation: \(error)", to: stderr)
                return 1
            }
        case .error(let msg):
            emit(msg, to: stderr)
            return 1
        default:
            emit("unexpected response for flow recommend", to: stderr)
            return 1
        }
    }

    func snooze(worktreeRef: String, until: FlowHoldUntil = .manualRefresh, reason: String?) -> Int32 {
        expectOk(transport.send(.flowSnooze(worktreeRef: worktreeRef, until: until, reason: reason)))
    }

    func note(worktreeRef: String) -> Int32 {
        do {
            let body = try stdin()
            guard !body.isEmpty else {
                emit("note body is required", to: stderr)
                return 1
            }
            return expectOk(transport.send(.flowNote(worktreeRef: worktreeRef, body: body)))
        } catch {
            emit("failed to read note stdin: \(error)", to: stderr)
            return 1
        }
    }

    func summary(worktreeRef: String) -> Int32 {
        let body: String
        do {
            body = try stdin()
        } catch {
            emit("failed to read summary stdin: \(error)", to: stderr)
            return 1
        }

        do {
            let summary = try JSONDecoder.flowState.decode(FlowWorktreeSummary.self, from: Data(body.utf8))
            guard summary.worktreeRef == worktreeRef else {
                emit("summary worktreeRef '\(summary.worktreeRef)' does not match argument '\(worktreeRef)'", to: stderr)
                return 1
            }
            return expectOk(transport.send(.flowSummary(summary)))
        } catch {
            emit("invalid summary JSON: \(error)", to: stderr)
            return 1
        }
    }

    func publish() -> Int32 {
        do {
            return expectOk(transport.send(.flowPublish(rawJSON: try stdin())))
        } catch {
            emit("failed to read publish stdin: \(error)", to: stderr)
            return 1
        }
    }

    func requestStatus(worktreeRef: String, explicit: Bool) -> Int32 {
        expectOk(transport.send(.flowRequestStatus(worktreeRef: worktreeRef, explicit: explicit)))
    }

    private func expectOk(_ response: ResponseMessage) -> Int32 {
        switch response {
        case .ok:
            return 0
        case .error(let msg):
            emit(msg, to: stderr)
            return 1
        default:
            emit("unexpected response for flow command", to: stderr)
            return 1
        }
    }

    private func handleUnexpectedResponse(_ response: ResponseMessage, expected: String) -> Int32 {
        switch response {
        case .error(let msg):
            emit(msg, to: stderr)
        default:
            emit("unexpected response for \(expected)", to: stderr)
        }
        return 1
    }
}

private enum FlowStdinInput {
    static func readAll() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private enum FlowHoldUntilCLI {
    static func parse(_ value: String) throws -> FlowHoldUntil {
        let data = try JSONEncoder().encode(value)
        do {
            return try JSONDecoder.flowState.decode(FlowHoldUntil.self, from: data)
        } catch {
            throw ValidationError("--until must be one of: next_focus_break, manual_refresh, or an ISO8601 timestamp")
        }
    }
}

private func emit(_ msg: String, to sink: TextSink) {
    sink.write("graftty: \(msg)\n")
}
