import SwiftUI
import Observation
import GrafttyProtocol

/// A completed tab keeps its place while its retained content is fetched on demand.
public struct AgentConversationView: View {
    public let agent: AgentSessionInfo
    private let request: @MainActor (AgentConversationAction) async throws -> WorktreeManagementResponse
    @State private var content = AgentConversationContent()

    public init(agent: AgentSessionInfo, request: @escaping @MainActor (AgentConversationAction) async throws -> WorktreeManagementResponse) {
        self.agent = agent; self.request = request
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(content.resumed ? "Resuming session…" : AgentAssignmentStatus(agent: agent, needsInput: false).label)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Resume session") { Task { await content.resume(agent: agent, request: request) } }
                    .disabled(content.resuming || content.resumed || !(content.detail?.canResume ?? agent.canResume ?? false))
            }.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result = content.detail?.result ?? agent.result { Text(result).textSelection(.enabled) }
                    if let transcript = content.detail?.transcript { Text(transcript).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if let failure = content.failure ?? content.detail?.failure ?? agent.failure {
                        Text(failure).foregroundStyle(.secondary)
                        Button("Retry loading") { Task { await content.read(agent: agent, request: request) } }
                    }
                    if agent.canResume == false { Text("This session has no saved conversation to resume.").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .task(id: "\(agent.assignmentID ?? agent.id)/\(agent.status)/\(agent.transcriptRevision ?? "")") {
            await content.read(agent: agent, request: request)
        }
    }

}

/// Reads can be superseded by a newer archive revision without releasing a resume in flight.
@MainActor @Observable
final class AgentConversationContent {
    private(set) var detail: AgentConversationDetail?
    private(set) var failure: String?
    private(set) var resuming = false
    private(set) var resumed = false
    private var identity: String?
    private var readID: UUID?
    private var resumeID: UUID?

    private func select(_ agent: AgentSessionInfo) -> String {
        let key = "\(agent.id)/\(agent.assignmentID ?? "")"
        if identity != key {
            identity = key
            detail = nil; failure = nil; resumed = false; resuming = false
            readID = nil; resumeID = nil
        }
        return key
    }

    func read(agent: AgentSessionInfo,
              request: @MainActor (AgentConversationAction) async throws -> WorktreeManagementResponse) async {
        let key = select(agent), id = UUID()
        readID = id
        failure = nil
        do {
            let response = try await request(.read)
            guard !Task.isCancelled, identity == key, readID == id else { return }
            switch response {
            case .agentConversation(let value):
                guard value.agentID == agent.id, value.assignmentID == agent.assignmentID else {
                    failure = "The conversation changed. Reload to see its current result."; return
                }
                detail = value
            case .error(_, let message, _, _): failure = message
            default: failure = "This host does not support saved conversations yet."
            }
        } catch {
            if !Task.isCancelled, identity == key, readID == id { failure = error.localizedDescription }
        }
    }

    func resume(agent: AgentSessionInfo,
                request: @MainActor (AgentConversationAction) async throws -> WorktreeManagementResponse) async {
        let key = select(agent)
        guard !resuming, !resumed else { return }
        let id = UUID()
        resumeID = id; resuming = true; failure = nil
        defer { if resumeID == id { resuming = false } }
        do {
            let response = try await request(.resume)
            guard identity == key, resumeID == id else { return }
            switch response {
            case .agentConversation(let value):
                guard value.agentID == agent.id else { failure = "The host returned another session."; return }
                resumed = true
            case .error(_, let message, _, _): failure = message
            default: failure = "This host does not support saved conversations yet."
            }
        } catch { if identity == key, resumeID == id { failure = error.localizedDescription } }
    }
}
