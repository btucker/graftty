#if canImport(AppKit)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct LowPowerRenderingTests {
    private func png() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test("@spec IOS-10.11: When a view shows a project icon it has already decoded, the application shall reuse the decoded image instead of decoding the icon data again.")
    func projectIconsDecodeOnce() throws {
        let data = try png()
        let first = try #require(ProjectIconImage.platformImage(data))
        // A separate copy of the same bytes, as a new frame from the host delivers.
        let second = try #require(ProjectIconImage.platformImage(Data(data)))
        #expect(first === second)
        #expect(ProjectIconImage.platformImage(Data("not an image".utf8)) == nil)
    }

    @Test("@spec IOS-10.12: While Low Power Mode is on, the application shall draw the worktree header wash without its blurred smear, keeping the watermark and gradient.")
    func lowPowerDropsTheSmear() throws {
        let wash = try #require(WorktreeHeaderWash(emoji: "🧪", background: .black, isDark: true))
        #expect(WorktreeHeaderWashView(wash: wash, isLowPower: false).drawsSmear)
        #expect(!WorktreeHeaderWashView(wash: wash, isLowPower: true).drawsSmear)
    }
}
#endif
