#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

private struct TerminalControlsGroupedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var terminalControlsGrouped: Bool {
        get { self[TerminalControlsGroupedKey.self] }
        set { self[TerminalControlsGroupedKey.self] = newValue }
    }
}

struct TerminalFloatingGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.35), lineWidth: 0.5))
        }
    }
}

/// One continuous background; the buttons retain their own touch targets.
struct TerminalFloatingControlGroup<Content: View>: View {
    var isVisible = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.terminalControlsGrouped, true)
            .background {
                Capsule().fill(.clear)
                    .modifier(TerminalFloatingGlass())
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

private struct TerminalFloatingButtonBackground: ViewModifier {
    @Environment(\.terminalControlsGrouped) private var grouped

    @ViewBuilder
    func body(content: Content) -> some View {
        if grouped { content }
        else { content.modifier(TerminalFloatingGlass()) }
    }
}

/// Shared floating terminal control for Back, keyboard and browser actions.
/// The plain style keeps each glyph in the primary foreground.
struct TerminalFloatingGlyphButton: View {
    let systemName: String
    let accessibilityLabel: String
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy { ProgressView().tint(Color.primary) }
                else { Image(systemName: systemName) }
            }
                .font(.title2)
                .foregroundStyle(.primary)
                .padding(10)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .modifier(TerminalFloatingButtonBackground())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct TerminalFloatingControlPlacement: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, 12)
            .padding(.top, 12)
    }
}
#endif
