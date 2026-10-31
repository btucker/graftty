import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Provider identity uses template tint, independent of attention/status color.
@MainActor
public struct AgentProviderIcon: View {
    public let provider: String?
    public var size: CGFloat
    public init(provider: String?, size: CGFloat = 16) { self.provider = provider; self.size = size }
    private static let claude = load("claude")
    private static let codex = load("codex")

    static func providerImage(_ provider: String?) -> Image? {
        switch provider {
        case "claude": claude
        case "codex": codex
        default: nil
        }
    }

    private static func load(_ name: String) -> Image? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
        #endif
    }

    public var body: some View {
        Group {
            if let image = Self.providerImage(provider) {
                image.resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: "terminal").resizable().scaledToFit().padding(2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider == "claude" ? "Claude" : provider == "codex" ? "Codex" : "Terminal")
    }
}
