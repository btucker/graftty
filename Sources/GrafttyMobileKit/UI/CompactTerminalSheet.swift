#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol

struct CompactTerminalSheet<Content: View>: View {
    let worktree: WorktreePanes
    @Bindable var presentation: CompactTerminalPresentation
    let create: () async throws -> String?
    var theme: GhosttyThemeColors = .fallback
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(CompactTerminalPresentation.terminals(in: worktree), id: \.sessionName) { terminal in
                        Button(terminal.displayTitle) { presentation.select(terminal.sessionName, in: worktree) }
                    }
                } label: {
                    Label("Choose terminal", systemImage: "terminal")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }.disabled(CompactTerminalPresentation.terminals(in: worktree).isEmpty)
                Spacer(minLength: 0)
                Button { Task { await presentation.newTerminal(create: create) } } label: {
                    Image(systemName: "plus").frame(width: 36, height: 36)
                }.disabled(presentation.isCreating || presentation.pendingUntil != nil).accessibilityLabel("New terminal")
                Button { presentation.isPresented = false } label: {
                    Image(systemName: "xmark").frame(width: 36, height: 36)
                }.accessibilityLabel("Hide terminal")
            }.font(.callout).buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 12)
                .foregroundStyle(theme.foreground).background(theme.background)
            if let error = presentation.error {
                Text(error).font(.callout).foregroundStyle(.secondary).padding()
            }
            if let selected = presentation.selectedSession {
                content(selected).id(selected)
            } else if presentation.isCreating || presentation.pendingUntil != nil {
                ProgressView("Opening terminal…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Image(systemName: "terminal").accessibilityLabel("No open terminals")
                } description: {
                    Text("Use + to open a terminal in this worktree.")
                }
            }
        }
        .onChange(of: worktree, initial: true) { _, current in presentation.reconcile(in: current) }
        .task(id: presentation.pendingUntil) {
            guard let deadline = presentation.pendingUntil else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            presentation.expirePendingCreation()
        }
        .ignoresSafeArea(.keyboard)
        .foregroundStyle(theme.foreground)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .presentationBackground(theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
#endif
