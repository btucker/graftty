import SwiftUI
import GrafttyProtocol

/// The Chat view of a running agent tab: the shared conversation, any request
/// the provider is waiting on, and this viewer's draft.
public struct AgentChatView: View {
    @Bindable private var model: AgentChatModel
    private let tabID: String
    private let connection: AgentChatConnection
    private let showTerminal: () -> Void
    @FocusState private var composerFocused: Bool
    @State private var highlighted = 0
    /// The draft for which the user dismissed the menu with Escape.
    @State private var dismissedDraft: String?
    /// Counts the viewer's requests to attach again after a failure.
    @State private var attempt = 0

    public init(
        model: AgentChatModel, tabID: String, connection: AgentChatConnection,
        showTerminal: @escaping () -> Void
    ) {
        self.model = model
        self.tabID = tabID
        self.connection = connection
        self.showTerminal = showTerminal
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let reason = model.unavailable {
                unavailable(reason)
            } else if let snapshot = model.snapshot {
                transcript(snapshot)
                ForEach(snapshot.requests) { request in requestCard(request) }
                if snapshot.requests.isEmpty, snapshot.turnState == .waitingOnRequest, snapshot.endedReason == nil {
                    // Asked before Chat attached, so only the terminal has it.
                    requestCard(AgentChatPendingRequest(
                        id: "unlisted", kind: .other, summary: title(for: .other), canAnswerInChat: false
                    ))
                }
                if let ended = snapshot.endedReason {
                    Text(ended).font(.callout).foregroundStyle(.secondary).padding(12)
                } else {
                    composer
                }
            } else {
                ProgressView("Loading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(tabID)/\(attempt)") {
            await model.run(connection)
        }
        .onAppear { composerFocused = true }
    }

    private func unavailable(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Text(reason).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("Try Again") { attempt += 1 }
                Button("Show Terminal", action: showTerminal)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcript(_ snapshot: AgentChatSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.items) { item in AgentChatRow(item: item) }
                if snapshot.turnState == .active {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.callout).italic().foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .defaultScrollAnchor(.bottom)
    }

    private func requestCard(_ request: AgentChatPendingRequest) -> some View {
        let heading = title(for: request)
        return VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.callout.weight(.medium))
            // A request Chat cannot describe has only its heading to show.
            if request.summary != heading {
                Text(request.summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            if let detail = request.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if request.canAnswerInChat {
                    Button("Approve") { answer(request, .accept) }
                    Button("Approve for session") { answer(request, .acceptForSession) }
                    Button("Decline") { answer(request, .decline) }
                } else {
                    // Switching views leaves the decision pending in the terminal.
                    Button("Answer in Terminal", action: showTerminal)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .accessibilityElement(children: .contain)
    }

    private func title(for request: AgentChatPendingRequest) -> String { title(for: request.kind) }

    private func title(for kind: AgentChatPendingRequest.Kind) -> String {
        switch kind {
        case .commandApproval: "The agent wants to run a command"
        case .fileChangeApproval: "The agent wants to change files"
        case .other: "The agent is waiting for an answer"
        }
    }

    private func answer(_ request: AgentChatPendingRequest, _ decision: AgentChatDecision) {
        Task { await model.answer(request, decision) }
    }

    private var composer: some View {
        let matches = dismissedDraft == model.draft ? [] : model.slashMatches
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
            if !matches.isEmpty { slashMenu(matches) }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $model.draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 22, maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($composerFocused)
                    .accessibilityLabel("Message")
                    .onKeyPress(phases: .down) { press in handle(press, matches: matches) }
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.plain)
                    .disabled(!model.canSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onChange(of: matches.map(\.id)) { _, _ in highlighted = 0 }
    }

    private func slashMenu(_ matches: [AgentChatCommand]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                    Button { choose(command) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(command.invocation).font(.system(.callout, design: .monospaced))
                            if let hint = command.argumentHint {
                                Text(hint).font(.callout).foregroundStyle(.tertiary)
                            }
                            Text(command.description).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(index == highlighted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                }
            }
        }
        .frame(maxHeight: 180)
        .accessibilityLabel("Commands")
    }

    /// Hardware keys only. On the software keyboard Return adds a line and
    /// the Send button submits.
    private func handle(_ press: KeyPress, matches: [AgentChatCommand]) -> KeyPress.Result {
        if !matches.isEmpty {
            switch press.key {
            case .downArrow:
                highlighted = min(highlighted + 1, matches.count - 1)
                return .handled
            case .upArrow:
                highlighted = max(highlighted - 1, 0)
                return .handled
            case .return:
                choose(matches[min(highlighted, matches.count - 1)])
                return .handled
            case .escape:
                dismissedDraft = model.draft
                return .handled
            default:
                return .ignored
            }
        }
        guard press.key == .return, !press.modifiers.contains(.shift) else { return .ignored }
        send()
        return .handled
    }

    private func choose(_ command: AgentChatCommand) {
        model.choose(command)
        composerFocused = true
    }

    private func send() {
        Task { await model.send() }
    }
}

private struct AgentChatRow: View {
    let item: AgentChatItem

    var body: some View {
        switch item.kind {
        case .user:
            Text(item.text).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("You: \(item.text)")
        case .agent:
            Text(Self.rich(item.text)).textSelection(.enabled)
        case .reasoning:
            Text(Self.rich(item.text)).font(.callout).italic().foregroundStyle(.secondary)
        case .command:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                if let output = item.detail, !output.isEmpty {
                    Text(output).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(12).textSelection(.enabled)
                }
            }
            .opacity(item.isComplete ? 1 : 0.6)
        case .fileChange, .tool, .notice:
            Text(item.text).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Inline Markdown only: emphasis, code spans, and links, with line breaks kept.
    private static func rich(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
