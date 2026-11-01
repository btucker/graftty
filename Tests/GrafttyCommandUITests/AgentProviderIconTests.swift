import AppKit
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct AgentProviderIconTests {
    @Test("@spec AGENT-6.123: When a provider mark appears in a native Mac menu, the application shall use a 16-point template image so menu rows keep their standard size and tint.", arguments: ["claude", "codex"])
    func nativeMenuMarkHasStandardSize(_ provider: String) throws {
        let image = try #require(AgentProviderIcon.nativeProviderImage(provider))
        #expect(image.size == NSSize(width: 16, height: 16))
        #expect(image.isTemplate)
    }

    @Test("@spec AGENT-6.120: While an agent provider icon is displayed, the application shall render the bundled Claude or Codex mark with visible template tint.", arguments: ["claude", "codex"])
    func providerMarkRenders(_ provider: String) throws {
        #expect(AgentProviderIcon.providerImage(provider) != nil)
        let host = NSHostingView(rootView: AgentProviderIcon(provider: provider, size: 48)
            .foregroundStyle(.white).frame(width: 64, height: 64).background(.black)
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var visible = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.5 && color.greenComponent > 0.5 && color.blueComponent > 0.5 { visible += 1 }
            }
        }
        #expect(visible > 20, "The provider mark must not render as an empty image")
    }
}
