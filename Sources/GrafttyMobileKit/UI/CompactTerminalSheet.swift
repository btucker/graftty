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
        let terminals = CompactTerminalPresentation.terminals(in: worktree)
        let mounted = presentation.mountedTerminal(in: terminals)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    Picker("Choose terminal", selection: Binding(
                        get: { mounted?.sessionName },
                        set: { if let session = $0 { presentation.select(session) } }
                    )) {
                        ForEach(terminals, id: \.sessionName) { terminal in
                            Text(terminal.displayTitle).tag(Optional(terminal.sessionName))
                        }
                        if let mounted, !terminals.contains(where: { $0.sessionName == mounted.sessionName }) {
                            Text(mounted.displayTitle).tag(Optional(mounted.sessionName))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").frame(width: mounted == nil ? 44 : 24)
                        if let mounted {
                            Text(mounted.displayTitle).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Choose terminal")
                .accessibilityValue(mounted?.displayTitle ?? "")
                .disabled(terminals.isEmpty && mounted == nil)
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
            if let mounted {
                content(mounted.sessionName).id(mounted.sessionName)
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
