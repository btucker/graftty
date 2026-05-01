import SwiftUI
import AppKit
import GrafttyKit

/// SwiftUI window scoped to one team's inbox. Tails
/// `<rootDirectory>/<teamID>/messages.jsonl` via `TeamInboxObserver`
/// (TEAM-7.4) and renders each row through `TeamActivityLogRow`
/// (TEAM-7.5 / TEAM-7.7).
///
/// View-only — no compose UI, and no cursor/watermark mutations. The
/// hook handler maintains its own delivery state independently.
struct TeamActivityLogWindow: View {
    @State private var viewModel: TeamActivityLogViewModel
    let messagesFileURL: URL

    init(rootDirectory: URL, teamID: String, teamName: String) {
        _viewModel = State(initialValue: TeamActivityLogViewModel(
            rootDirectory: rootDirectory,
            teamID: teamID,
            teamName: teamName
        ))
        self.messagesFileURL = TeamInbox.messagesURLFor(
            rootDirectory: rootDirectory,
            teamID: teamID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Team Activity — \(viewModel.teamName)")
                    .font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([messagesFileURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal messages.jsonl in Finder")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if viewModel.messages.isEmpty {
                Spacer()
                Text("No team activity yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.messages, id: \.id) { msg in
                                TeamActivityLogRow(message: msg).id(msg.id)
                            }
                        }
                        .padding()
                    }
                    // Auto-scroll to the newest row whenever the
                    // tail-id changes (a new append landed). Keying
                    // off `.last?.id` rather than `.count` makes the
                    // trigger stable across initial-state emits.
                    .onChange(of: viewModel.messages.last?.id) { _, newID in
                        if let newID {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(newID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}
