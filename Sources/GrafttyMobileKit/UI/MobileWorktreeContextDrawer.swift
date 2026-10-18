#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// An edge gesture and an explicit button share a drawer without remounting the terminal.
struct MobileWorktreeContextDrawer: ViewModifier {
    let context: SidebarWorktreeContext?
    @Environment(\.biometricGate) private var gate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
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
            .overlay(alignment: .top) {
                if context != nil, !isPresented {
                    Button(action: open) {
                        Label("Context", systemImage: "text.alignleft")
                            .font(.callout).fontWeight(.medium)
                            .padding(.horizontal, 12).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityLabel("Worktree context")
                    .accessibilityIdentifier("worktree.context.open")
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
                            WorktreeContextPanel(context: context, onClose: close)
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
