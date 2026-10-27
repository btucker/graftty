#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

private struct OpenWorktreeContextKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var openWorktreeContext: (() -> Void)? {
        get { self[OpenWorktreeContextKey.self] }
        set { self[OpenWorktreeContextKey.self] = newValue }
    }
}

/// An edge gesture and an explicit button share a drawer without remounting the terminal.
struct MobileWorktreeContextDrawer: ViewModifier {
    let context: SidebarWorktreeContext?
    var showsStandaloneControl = false
    @Environment(\.biometricGate) private var gate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWorktreeContext) private var inheritedOpen
    @Environment(\.worktreeContextActions) private var contextActions
    @State private var isPresented = false
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // iPad owns one drawer around its panes. A pane's empty local
            // modifier must preserve that enclosing drawer's action.
            .environment(\.openWorktreeContext, context == nil ? inheritedOpen : open)
            .accessibilityHidden(isPresented)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { width = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, value in width = value }
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                guard context != nil, !isPresented else { return }
                if MobileContextDrawerGesture.shouldOpen(startX: value.startLocation.x, width: width,
                    x: value.translation.width, y: value.translation.height) { open() }
            })
            .overlay(alignment: .topTrailing) {
                if showsStandaloneControl, context != nil, !isPresented {
                    TerminalFloatingGlyphButton(systemName: "text.alignleft", accessibilityLabel: "Worktree context",
                        action: open)
                        .accessibilityIdentifier("worktree.context.open")
                        .padding(12)
                }
            }
            .overlay {
                if isPresented, let context {
                    GeometryReader { geometry in
                        ZStack(alignment: .trailing) {
                            Color.black.opacity(0.25)
                                .contentShape(Rectangle())
                                .onTapGesture { close() }
                                .accessibilityLabel("Close context")
                                .accessibilityAddTraits(.isButton)
                            WorktreeContextPanel(context: context, collapsesBrief: true, onClose: close)
                                .environment(\.worktreeContextActions, navigationActions)
                                .accessibilityAddTraits(.isModal)
                                .frame(width: min(420, max(0, geometry.size.width - 20)))
                                .frame(maxHeight: .infinity)
                                .background(.background)
                                .shadow(color: .black.opacity(0.2), radius: 18, x: -4)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                    .accessibilityAction(.escape, close)
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { close() } }
            .onChange(of: gate?.state) { _, state in if state == .locked { close() } }
            .onChange(of: context == nil) { _, missing in if missing { close() } }
    }

    private var navigationActions: WorktreeContextActions? {
        contextActions.map { actions in
            WorktreeContextActions(openWorktree: { path, source in
                guard actions.openWorktree(path, source) else { return false }
                close()
                return true
            }, revealInTerminal: actions.revealInTerminal.map { reveal in
                { request in
                    // The drawer covers the terminal, so close it once the pane has scrolled.
                    guard await reveal(request) else { return false }
                    close()
                    return true
                }
            })
        }
    }

    private func open() {
        guard gate?.state != .locked else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.22)) { isPresented = true }
    }

    private func close() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.22)) { isPresented = false }
    }
}
#endif
