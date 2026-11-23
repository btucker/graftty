import SwiftUI
import GrafttyProtocol

/// The Chat view of a running agent tab: the shared conversation, any request
/// the provider is waiting on, and this viewer's draft. Every colour derives
/// from the foreground style and tint its owner sets, so it follows the
/// terminal theme.
public struct AgentChatView: View {
    @Bindable private var model: AgentChatModel
    private let tabID: String
    private let agentName: String
    private let connection: AgentChatConnection
    private let showTerminal: () -> Void
    @FocusState private var composerFocused: Bool
    @State private var highlighted = 0
    /// The draft for which the user dismissed the menu with Escape.
    @State private var dismissedDraft: String?
    /// Counts the viewer's requests to attach again after a failure.
    @State private var attempt = 0

    public init(
        model: AgentChatModel, tabID: String, agentName: String, connection: AgentChatConnection,
        showTerminal: @escaping () -> Void
    ) {
        self.model = model
        self.tabID = tabID
        self.agentName = agentName
        self.connection = connection
        self.showTerminal = showTerminal
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let reason = model.unavailable {
                unavailable(reason)
            } else if let snapshot = model.snapshot {
                let expanded = model.isDraftExpanded && snapshot.endedReason == nil
                if expanded { lastReply(snapshot) } else { transcript(snapshot) }
                ForEach(snapshot.requests) { request in requestCard(request) }
                if snapshot.requests.isEmpty, snapshot.turnState == .waitingOnRequest, snapshot.endedReason == nil {
                    // Asked before Chat attached, so only the terminal has it.
                    requestCard(AgentChatPendingRequest(
                        id: "unlisted", kind: .other, summary: title(for: .other), canAnswerInChat: false
                    ))
                }
                if let ended = snapshot.endedReason {
                    Text(ended).font(.callout).foregroundStyle(.secondary).padding(12)
                } else if expanded {
                    draftCard
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
        .onChange(of: model.isDraftExpanded) { _, _ in
            // Expanding swaps in another editor. Focus it once it is on
            // screen, so the keyboard stays up.
            Task { composerFocused = true }
        }
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
        let heading = title(for: request.kind)
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

    /// The command the typed slash would choose, and how many others match.
    private var matches: [AgentChatCommand] {
        dismissedDraft == model.draft ? [] : model.slashMatches
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.isBrowsingCommands { matchRow }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if model.snapshot?.commands.isEmpty == false {
                    Button(
                        model.isBrowsingCommands ? "Hide Commands" : "Commands",
                        systemImage: model.isBrowsingCommands ? "keyboard" : "square.grid.2x2"
                    ) {
                        model.isBrowsingCommands.toggle()
                        composerFocused = !model.isBrowsingCommands
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(model.isBrowsingCommands ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 36, height: 36)
                    .background(.primary.opacity(0.09), in: Circle())
                }
                HStack(alignment: .bottom, spacing: 0) {
                    compactEditor
                    Button("Expand Draft", systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.isBrowsingCommands = false
                        model.isDraftExpanded = true
                    }
                    .labelStyle(.iconOnly).font(.footnote).foregroundStyle(.secondary)
                    .frame(width: 30, height: 36)
                }
                .padding(.leading, 6)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.16)))
                if !model.draft.isEmpty, matches.isEmpty { sendButton.frame(height: 36) }
            }
            .buttonStyle(.plain)
            if model.isBrowsingCommands { commandList }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .onChange(of: matches.map(\.id)) { _, _ in highlighted = 0 }
        .onChange(of: composerFocused) { _, focused in
            // Typing again brings the keyboard back in the list's place. An
            // unchanged value is not written: every write redraws the view.
            if focused, model.isBrowsingCommands { model.isBrowsingCommands = false }
        }
    }

    /// The editor at one to three lines. A hidden copy of the draft sets the
    /// height: an editor asked for its own ideal size makes UIKit lay out
    /// without end when the view opens with the keyboard.
    private var compactEditor: some View {
        // A trailing line break has no height of its own in a label.
        Text(model.draft.isEmpty || model.draft.hasSuffix("\n") ? model.draft + " " : model.draft)
            .font(.body)
            .lineLimit(1...3)
            .padding(Self.editorInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay { editor }
            .padding(.vertical, Self.editorMargin)
    }

    #if os(macOS)
    private static let editorInsets = EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5)
    private static let editorMargin: CGFloat = 9
    #else
    /// The space UIKit's text view keeps around its text.
    private static let editorInsets = EdgeInsets(top: 8, leading: 5, bottom: 8, trailing: 5)
    private static let editorMargin: CGFloat = 0
    #endif

    private var editor: some View {
        TextEditor(text: $model.draft)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($composerFocused)
            .accessibilityLabel("Message")
            .onKeyPress(phases: .down) { press in handle(press, matches: matches) }
            .overlay(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text("Message \(agentName)").foregroundStyle(.tertiary)
                        .padding(Self.editorInsets)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }

    private var sendButton: some View {
        Button(action: send) {
            // The arrow is cut out of the disc, so it shows the theme's
            // background whatever that is.
            ZStack {
                Circle().fill(.primary)
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send")
        .disabled(!model.canSend)
        .opacity(model.canSend ? 1 : 0.35)
    }

    /// One line for what the typed slash matches. Up and Down move through
    /// the other matches.
    @ViewBuilder private var matchRow: some View {
        let matches = matches
        if !matches.isEmpty {
            let command = matches[min(highlighted, matches.count - 1)]
            Button { choose(command) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(command.invocation).font(.system(.callout, design: .monospaced).weight(.medium))
                    Text(command.description).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if matches.count > 1 {
                        Text("+\(matches.count - 1)").font(.caption).foregroundStyle(.tertiary)
                            .accessibilityLabel("\(matches.count - 1) more")
                    }
                }
                .padding(.horizontal, 14).frame(height: 36)
                .background(.primary.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// Every command the agent offers, shown where the keyboard was.
    private var commandList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(agentName) commands").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
                ForEach(model.snapshot?.commands ?? []) { command in
                    Button { choose(command) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(command.invocation).font(.system(.callout, design: .monospaced).weight(.medium))
                                if let hint = command.argumentHint {
                                    Text(hint).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                            }
                            Text(command.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
        }
        .frame(height: 300)
        .accessibilityLabel("Commands")
    }

    /// The agent's latest reply, kept in view above an expanded draft.
    @ViewBuilder private func lastReply(_ snapshot: AgentChatSnapshot) -> some View {
        if let reply = snapshot.items.last(where: { $0.kind == .agent }) {
            Button { model.isDraftExpanded = false } label: {
                HStack(spacing: 6) {
                    Text(agentName).font(.caption.weight(.semibold))
                    Text(reply.text.replacingOccurrences(of: "\n", with: " ")).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show conversation")
        }
    }

    /// The draft at full height, for a message of many lines.
    private var draftCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button("Collapse Draft", systemImage: "chevron.down") { model.isDraftExpanded = false }
                    .labelStyle(.iconOnly).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                Text("Draft to \(agentName)").font(.subheadline.weight(.semibold))
                Spacer()
                sendButton
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider().opacity(0.5)
            editor.padding(.horizontal, 8).padding(.top, 4).frame(maxHeight: .infinity)
            matchRow.padding(.horizontal, 8).padding(.bottom, 6)
            if let notice = model.notice {
                Divider().opacity(0.5)
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.14)))
        .padding(.horizontal, 8).padding(.bottom, 8)
        .onChange(of: matches.map(\.id)) { _, _ in highlighted = 0 }
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
            // Markdown is parsed once the row is complete, not on every streamed token.
            Text(item.isComplete ? Self.rich(item.text) : AttributedString(item.text)).textSelection(.enabled)
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

/// The segmented Chat / Terminal control in an agent tab's header.
public struct AgentChatSwitch: View {
    @Binding private var showsChat: Bool

    public init(showsChat: Binding<Bool>) { _showsChat = showsChat }

    public var body: some View {
        Picker("View", selection: $showsChat) {
            Text("Chat").tag(true)
            Text("Terminal").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .padding(.horizontal, 8)
        .accessibilityIdentifier("workspace.chat.switch")
    }
}
