import GrafttyWatchKit
import SwiftUI

struct WatchInboxView: View {
    let connection: WatchPhoneConnection
    @State private var path: [String] = []
    private var inbox: WatchInboxModel { connection.inbox }

    init(connection: WatchPhoneConnection) {
        self.connection = connection
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--watch-preview-terminal") {
            _path = State(initialValue: ["terminal-preview"])
        }
        if ProcessInfo.processInfo.arguments.contains("--watch-preview-question"), let card = connection.inbox.snapshot.cards.first {
            _path = State(initialValue: [card.id])
        }
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if inbox.snapshot.isEnabled {
                    NavigationLink {
                        WatchTerminalListView(connection: connection)
                    } label: { Label("Terminals", systemImage: "terminal") }
                }
                if !inbox.snapshot.isEnabled {
                    Label("Enable Apple Watch in Graftty's Hosts screen on your iPhone.", systemImage: "iphone")
                        .font(.footnote)
                } else if inbox.snapshot.cards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: inbox.snapshot.updatedAt == .distantPast ? "arrow.triangle.2.circlepath" : "checkmark.bubble")
                            .font(.title2).foregroundStyle(.mint)
                        Text(emptyTitle).font(.headline)
                        Text(emptyDetail)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(inbox.snapshot.cards) { card in
                    NavigationLink(value: card.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.project + " · " + card.worktree)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            Text(card.question).font(.headline).lineLimit(3)
                            if inbox.replyState(for: card) == .sent {
                                Label("Sent", systemImage: "checkmark").font(.caption2).foregroundStyle(.mint)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                if inbox.snapshot.omittedCount > 0 {
                    Text("\(inbox.snapshot.omittedCount) more requests on iPhone.").font(.footnote)
                }
                if !inbox.snapshot.unavailableHosts.isEmpty {
                    Text("Unavailable: " + inbox.snapshot.unavailableHosts.joined(separator: ", ") + ". Requests may be out of date.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let error = inbox.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                Button { Task { await connection.refresh() } } label: {
                    if inbox.isRefreshing { ProgressView("Updating…") }
                    else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .disabled(inbox.isRefreshing)
                if inbox.snapshot.updatedAt != .distantPast {
                    Text("Updated \(inbox.snapshot.updatedAt, style: .relative) ago")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("Time since last update")
                }
            }
            .navigationTitle("Needs you")
            .navigationDestination(for: String.self) { cardID in
                #if DEBUG
                if cardID == "terminal-preview" {
                    WatchTerminalView(connection: connection, target: WatchPhoneConnection.previewTerminal)
                } else {
                    WatchQuestionView(connection: connection, cardID: cardID)
                }
                #else
                WatchQuestionView(connection: connection, cardID: cardID)
                #endif
            }
        }
    }

    private var emptyTitle: String {
        if inbox.snapshot.updatedAt == .distantPast { return "Connect to iPhone" }
        return inbox.snapshot.unavailableHosts.isEmpty ? "All caught up" : "Macs unavailable"
    }

    private var emptyDetail: String {
        if inbox.snapshot.updatedAt == .distantPast { return "Your worktree questions will appear here." }
        return inbox.snapshot.unavailableHosts.isEmpty ? "No worktrees need an answer." : "Refresh when your Macs are back online."
    }
}

private struct WatchQuestionView: View {
    let connection: WatchPhoneConnection
    let cardID: String
    @State private var reply = ""

    private var card: WatchAttentionCard? { connection.inbox.snapshot.cards.first { $0.id == cardID } }

    var body: some View {
        ScrollView {
            if let card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.project + " · " + card.host).font(.caption2).foregroundStyle(.secondary)
                    Text(card.question).font(.headline)
                    if let terminal = card.terminal {
                        NavigationLink {
                            WatchTerminalView(connection: connection, target: terminal)
                        } label: { Label("View terminal", systemImage: "terminal") }
                    }
                    if let context = card.context, !context.isEmpty {
                        NavigationLink("Context") {
                            ScrollView { Text(context).font(.body).padding(.horizontal, 4) }
                                .navigationTitle("Context")
                        }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.mint)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    }
                    if card.target != nil {
                        ForEach(Array(card.options.enumerated()), id: \.offset) { _, option in
                            Button { answer(card, text: option.label) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(option.label).font(.body.weight(.semibold))
                                        if option.suggested { Image(systemName: "star.fill").font(.caption2) }
                                    }
                                    if let cost = option.cost { Text(cost).font(.caption2).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .tint(option.suggested ? .mint : .gray)
                            .disabled(!canAnswer(card))
                        }
                        TextField("Your reply", text: $reply)
                            .disabled(!canAnswer(card))
                        Button("Send reply") { answer(card, text: reply) }
                            .disabled(!canAnswer(card) || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        replyStatus(card)
                    } else {
                        Text("Open the agent's terminal on iPhone or Mac to respond to this prompt.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                // A draft for an old question must never become an answer to its replacement.
                .onChange(of: card.questionID) { _, _ in reply = "" }
            } else {
                Label("This request has cleared.", systemImage: "checkmark.bubble")
            }
        }
        .navigationTitle(card?.worktree ?? "Request")
    }

    private func canAnswer(_ card: WatchAttentionCard) -> Bool {
        let state = connection.inbox.replyState(for: card)
        return state != .sending && state != .sent
    }

    @ViewBuilder private func replyStatus(_ card: WatchAttentionCard) -> some View {
        switch connection.inbox.replyState(for: card) {
        case .idle: EmptyView()
        case .sending: ProgressView("Sending…")
        case .sent: Label("Sent to agent", systemImage: "checkmark.circle.fill").foregroundStyle(.mint)
        case .failed(let message): Text(message).font(.footnote).foregroundStyle(.orange)
        }
    }

    private func answer(_ card: WatchAttentionCard, text: String) {
        Task {
            await connection.answer(card, text: text)
            if connection.inbox.replyState(for: card) == .sent { reply = "" }
        }
    }
}
