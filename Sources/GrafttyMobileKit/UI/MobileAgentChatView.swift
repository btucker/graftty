#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// Chat for one agent tab, through this device's connection to its host.
struct MobileAgentChatView: View {
    let host: Host
    let worktreePath: String
    let agent: AgentSessionInfo
    let model: AgentChatModel
    let theme: GhosttyThemeColors
    let showTerminal: () -> Void
    @Environment(\.remoteConnectionCoordinator) private var coordinator

    var body: some View {
        AgentChatView(
            model: model, tabID: "\(agent.id)/\(agent.assignmentID ?? "")",
            connection: coordinator?.agentChatConnection(worktreePath: worktreePath, agentID: agent.id, on: host)
                ?? AgentChatConnection(
                    open: { .unavailable("The host connection is unavailable.") },
                    submit: { _ in .rejected(.unavailable) }, answer: { _, _, _ in false }
                ),
            showTerminal: showTerminal
        )
        .foregroundStyle(theme.foreground)
        .background(theme.background)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

/// The segmented Chat / Terminal control in an iPad tab row.
struct MobileChatSwitch: View {
    @Binding var showsChat: Bool

    var body: some View {
        Picker("View", selection: $showsChat) {
            Text("Chat").tag(true)
            Text("Terminal").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .padding(.horizontal, 8)
        .accessibilityIdentifier("workspace.chat.switch")
    }
}
#endif
