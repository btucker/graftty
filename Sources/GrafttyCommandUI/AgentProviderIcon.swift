import SwiftUI

/// Provider identity uses template tint, independent of attention/status color.
public struct AgentProviderIcon: View {
    public let provider: String?
    public var size: CGFloat
    public init(provider: String?, size: CGFloat = 16) { self.provider = provider; self.size = size }
    public var body: some View {
        Group {
            if provider == "claude" || provider == "codex" {
                Image(provider!, bundle: .module).resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: "terminal").resizable().scaledToFit().padding(2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider == "claude" ? "Claude" : provider == "codex" ? "Codex" : "Terminal")
    }
}
