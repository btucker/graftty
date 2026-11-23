#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol
import GrafttyCommandUI

struct MobileAgentConversationView: View {
    let host: Host
    let worktreePath: String
    let agent: AgentSessionInfo
    @Environment(\.remoteConnectionCoordinator) private var coordinator

    var body: some View {
        AgentConversationView(agent: agent) { action in
            guard let coordinator else {
                return .error(code: "unavailable", message: "The host connection is unavailable.", forceAllowed: false, shortStatus: nil)
            }
            return try await coordinator.sendWorktreeManagement(.agentConversation(worktreeID: worktreePath,
                agentID: agent.id, action: action), to: host)
        }
    }
}

/// Saved rows stay readable after Codex has redrawn its terminal or paged out earlier turns.
struct MobileSavedMessagesView: View {
    let host: Host
    let path: String
    let agent: AgentSessionInfo
    let loadTerminalPage: (() -> Void)?
    @Environment(\.remoteConnectionCoordinator) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AgentConversationMessages.Item] = []
    @State private var cursor: UInt64? = 0
    @State private var failure: String?
    @State private var loading = false
    @State private var requestNumber = 0

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.speaker).fontWeight(.semibold)
                            Spacer()
                            if let timestamp = item.timestamp {
                                Text(Date(timeIntervalSinceReferenceDate: timestamp), style: .relative)
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(item.text).textSelection(.enabled)
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Retry") { requestNumber += 1 }
                } else if loading {
                    ProgressView("Loading messages…")
                } else if cursor != nil {
                    Button("Show more messages") { requestNumber += 1 }
                } else if items.isEmpty {
                    Text("No saved messages in this session.").foregroundStyle(.secondary)
                }
                if let loadTerminalPage {
                    Button("Load earlier terminal rows") { loadTerminalPage(); dismiss() }
                }
            }
            .navigationTitle("Earlier messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task(id: requestNumber) { await loadPage() }
        }
    }

    private func loadPage() async {
        guard let offset = cursor else { return }
        guard let coordinator else { failure = "The host connection is unavailable."; return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let result = try await coordinator.sendWorktreeManagement(.agentConversation(worktreeID: path,
                agentID: agent.id, action: .messages(from: offset)), to: host)
            guard !Task.isCancelled else { return }
            switch result {
            case .agentConversation(let detail) where detail.agentID == agent.id && detail.assignmentID == agent.assignmentID:
                guard let page = detail.messages, page.nextOffset.map({ $0 > offset }) ?? true else {
                    failure = "Update Graftty on the host to read saved messages."; return
                }
                var ids = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { ids.insert($0.id).inserted })
                cursor = page.nextOffset
            case .error(_, let message, _, _): failure = message
            default: failure = "The host could not return this session’s saved messages."
            }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
#endif
