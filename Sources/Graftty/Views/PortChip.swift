// Sources/Graftty/Views/PortChip.swift
import SwiftUI
import AppKit
import GrafttyKit

/// Single port-binding chip rendered next to a pane's title in the
/// sidebar. SF Symbol `personalhotspot` for `.loopback`, `globe` for
/// `.lan`. Click opens `http://localhost:<port>/` regardless of scope —
/// the icon (not the URL) communicates LAN exposure.
/// @spec PORTS-3.1
/// @spec PORTS-3.2
/// @spec PORTS-3.5
/// @spec PORTS-3.6
/// @spec PORTS-3.7
struct PortChip: View {
    let binding: PortBinding
    let theme: GhosttyTheme

    var body: some View {
        Button {
            if let url = Self.url(for: binding) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: Self.iconName(for: binding))
                    .font(.system(size: 9))
                    .foregroundColor(theme.foreground.opacity(0.85))
                Text(Self.label(for: binding))
                    .font(.system(size: 10.5, weight: .medium, design: .default))
                    .monospacedDigit()
                    .foregroundColor(theme.foreground)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 0)
            .background(
                Capsule().fill(theme.foreground.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(theme.foreground.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(Self.tooltip(for: binding))
        .accessibilityLabel(Self.accessibilityLabel(for: binding))
    }

    /// Visible chip text. Returns a non-localized `String` (rather than relying
    /// on SwiftUI's `LocalizedStringKey` interpolation) so the port digits
    /// don't pick up locale grouping separators — e.g., `:8080`, not `:8,080`.
    static func label(for binding: PortBinding) -> String {
        ":\(binding.port)"
    }

    static func url(for binding: PortBinding) -> URL? {
        URL(string: "http://localhost:\(binding.port)/")
    }

    static func tooltip(for binding: PortBinding) -> String {
        "Open http://localhost:\(binding.port)/"
    }

    static func accessibilityLabel(for binding: PortBinding) -> String {
        let scopeWord = binding.scope == .lan ? "LAN-reachable" : "localhost-only"
        return "Open \(binding.processName) on port \(binding.port) (\(scopeWord))"
    }

    /// Maps a binding's scope to its SF Symbol name.
    static func iconName(for binding: PortBinding) -> String {
        switch binding.scope {
        case .loopback: return "personalhotspot"
        case .lan:      return "globe"
        }
    }
}
