import ArgumentParser
import Foundation
import GrafttyKit

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create agents and manage assignment completion",
        subcommands: [AgentAdd.self, AgentList.self, AgentFinish.self, AgentClose.self, AgentResume.self])
}

struct AgentAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add",
        abstract: "Launch an agent in a new worktree or an existing worktree",
        discussion: """
        Omit --worktree to create a worktree. Use --worktree <name> to share an existing one.
        --provider overrides the host's Default agent setting. The result includes stable agent,
        assignment, and operation IDs. Creation is accepted asynchronously; use --wait to wait
        for the new worktree's launch. Existing-worktree agents share files with its implementer.
        When a child finishes, its parent receives a durable cleanup instruction.
        Native Claude and Codex subagents remain available for work within a session.
        """)
    @Argument(help: "Agent name; also the worktree name when creating a worktree") var name: String
    @Option(name: .long, help: "Existing worktree name or path") var worktree: String?
    @Option(name: .long, help: "claude or codex; defaults to the host's preference") var provider: String?
    @Option(name: .long, help: "Initial task") var prompt: String?
    @Flag(name: .long, help: "Read the initial task from stdin") var promptStdin = false
    @Option(name: .long, help: "Git revision for a new worktree") var base: String?
    @Flag(name: .long, help: "Wait until a new worktree accepts the launch") var wait = false
    @Option(name: .long, help: "Seconds to wait for launch") var timeout = 300
    @Flag(name: .long, help: "Print structured agent records") var json = false

    func validate() throws {
        if let provider, TeamHookRuntime(rawValue: provider) == nil { throw ValidationError("--provider must be claude or codex") }
        if prompt != nil && promptStdin { throw ValidationError("Use --prompt or --prompt-stdin, not both") }
        if worktree != nil && base != nil { throw ValidationError("--base applies only to a new worktree") }
        guard timeout > 0 else { throw ValidationError("--timeout must be positive") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("An agent name is required") }
    }

    func run() throws {
        let caller = try CLIEnv.resolveWorktree()
        let target = try worktree.map { address -> String in
            let (path, pane) = try CLIEnv.resolveAddress(address)
            guard pane == nil else { throw ValidationError("--worktree takes a worktree, not a pane") }
            return path
        }
        let initialTask = try promptStdin ? WorktreeAdd.readPromptFromStdin() : prompt
        if let error = WorktreeAgentLaunchCommand.validationError(prompt: initialTask) { throw ValidationError(error) }
        let request = AgentControlRequest(action: .add, callerWorktree: caller,
            callerAgentID: TeamMessageInput.currentAgentID(worktreePath: caller),
            paneSessionName: TeamRegisterPaneResolver.paneSessionName(env: ProcessInfo.processInfo.environment),
            name: name, worktree: target, provider: provider.flatMap(TeamHookRuntime.init(rawValue:)),
            prompt: initialTask, operationID: UUID().uuidString.lowercased(), base: base)
        let records = try AgentCLI.exchange(request)
        if wait, target == nil, let operation = records.first?.operationID {
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while true {
                let response = try CLIEnv.sendRequest(.worktreeCreateStatus(operationID: operation))
                let status = try CLIEnv.expect(response, for: "agent add") {
                    if case .worktreeCreate(let status) = $0 { status } else { nil }
                }
                if status.state == .ready { break }
                if status.state == .failed { throw ValidationError(status.error ?? "Agent launch failed") }
                guard Date() < deadline else { throw ValidationError("Launch is still pending. Inspect graftty worktree status \(operation).") }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        try AgentCLI.printRecords(records, json: json)
    }
}

struct AgentList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List agents and retained results in this project")
    @Option(name: .long, help: "Filter by the parent's exact agent ID") var parent: String?
    @Option(name: .long, help: "starting, running, waiting, awaiting-cleanup, closing, closed, or failed") var status: String?
    @Flag(name: .long) var json = false
    func validate() throws {
        if let status, ManagedAgent.Status(rawValue: status) == nil { throw ValidationError("Unknown agent status") }
    }
    func run() throws {
        var request = try AgentCLI.request(.list)
        request.parent = parent
        request.status = status.flatMap(ManagedAgent.Status.init(rawValue:))
        try AgentCLI.printRecords(AgentCLI.exchange(request), json: json)
    }
}

struct AgentFinish: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "finish", abstract: "Finish this assignment and notify its parent to clean up")
    @Argument(help: "Managed agent ID; defaults to this launched session") var id: String?
    @Option(name: .long, help: "Assignment ID; defaults to this session's launch assignment") var assignment: String?
    @Flag(name: .long, help: "Read the completed result from stdin") var resultStdin = false
    @Option(name: .long, help: "Completed result") var result: String?
    @Flag(name: .long) var json = false
    func validate() throws {
        guard resultStdin != (result != nil) else { throw ValidationError("Supply --result or --result-stdin") }
        if let assignment, UUID(uuidString: assignment) == nil { throw ValidationError("Invalid assignment ID") }
    }
    func run() throws {
        let env = ProcessInfo.processInfo.environment
        var request = try AgentCLI.request(.finish)
        request.agentID = id ?? env["GRAFTTY_MANAGED_AGENT_ID"]
        request.assignmentID = (assignment ?? env["GRAFTTY_ASSIGNMENT_ID"]).flatMap(UUID.init(uuidString:))
        guard request.agentID != nil, request.assignmentID != nil else {
            throw ValidationError("Supply the managed agent ID and --assignment from graftty agent list --json")
        }
        request.result = try resultStdin ? WorktreeAdd.readPromptFromStdin() : result
        try AgentCLI.printRecords(AgentCLI.exchange(request), json: json)
    }
}

struct AgentClose: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close", abstract: "Close a completed agent's terminal while retaining its result and worktree")
    @Argument var id: String
    @Option(name: .long, help: "Expected completion ID from the completion message") var completion: String
    @Flag(name: .long) var json = false
    func validate() throws {
        guard UUID(uuidString: completion) != nil else { throw ValidationError("Invalid completion ID") }
    }
    func run() throws {
        var request = try AgentCLI.request(.close)
        request.agentID = id
        request.completionID = UUID(uuidString: completion)
        try AgentCLI.printRecords(AgentCLI.exchange(request), json: json)
    }
}

struct AgentResume: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Begin a new assignment in an agent still awaiting cleanup")
    @Argument var id: String
    @Flag(name: .long) var json = false
    func run() throws {
        var request = try AgentCLI.request(.resume)
        request.agentID = id
        try AgentCLI.printRecords(AgentCLI.exchange(request), json: json)
    }
}

enum AgentCLI {
    static func request(_ action: AgentControlRequest.Action) throws -> AgentControlRequest {
        let caller = try CLIEnv.resolveWorktree()
        return .init(action: action, callerWorktree: caller,
            callerAgentID: TeamMessageInput.currentAgentID(worktreePath: caller),
            paneSessionName: TeamRegisterPaneResolver.paneSessionName(env: ProcessInfo.processInfo.environment))
    }
    static func exchange(_ request: AgentControlRequest) throws -> [AgentControlRecord] {
        try CapabilityProbe.require([.managedAgents], retryTransportFailuresUntil: Date().addingTimeInterval(5))
        return try CLIEnv.expect(CLIEnv.sendRequest(.agent(request)), for: "agent \(request.action.rawValue)") {
            if case .agents(let records) = $0 { records } else { nil }
        }
    }
    static func printRecords(_ records: [AgentControlRecord], json: Bool) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(records), as: UTF8.self))
        } else {
            for record in records {
                let agent = record.agent
                print("\(agent.id)  \(agent.status.rawValue)  \(agent.name)  worktree=\(record.worktree)")
                print("assignment=\(agent.assignmentID.uuidString)" + (record.operationID.map { " operation=\($0)" } ?? ""))
                if let completion = agent.completion {
                    print(completion.result)
                    if agent.status != .closed { print("cleanup=graftty agent close \(agent.id) --completion \(completion.id.uuidString)") }
                }
            }
        }
    }
}
