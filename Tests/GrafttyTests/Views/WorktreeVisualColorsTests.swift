import AppKit
import SwiftUI
import Testing
@testable import Graftty

@Suite("Worktree color identity") @MainActor
struct WorktreeVisualColorsTests {
    @Test("@spec LAYOUT-2.125: While a worktree has SVG artwork, the application shall use its persistent territory color for its name and related pane text, adjusting contrast for the theme and selection without recoloring Git or attention indicators.")
    func textColorsStayReadableInLightDarkAndSelectedTerritories() {
        for background in [NSColor(calibratedWhite: 0.15, alpha: 1), NSColor(calibratedWhite: 0.85, alpha: 1)] {
            for accent in [NSColor.systemOrange, .systemBlue, .systemGreen, .systemPurple] {
                let title = WorktreeVisualColors.readable(accent, on: background)
                #expect(WorktreeVisualColors.contrast(title, background) >= 4.5)
                let selected = WorktreeVisualColors.mix(background, .white, amount: 0.16)
                #expect(WorktreeVisualColors.contrast(WorktreeVisualColors.readable(accent, on: selected), selected) >= 4.5)
            }
        }
    }

    @Test("@spec LAYOUT-2.126: When the selected worktree changes, the application shall carry its persistent color across the native titlebar, sidebar header, and workspace header while retaining a single theme-fading gradient across terminal panes.")
    func chromeUpdatesForWorktreeColorChangesAndRestoresThemeWhenCleared() {
        var gate = WindowTintApplyGate()
        let window = NSObject()
        let theme = GhosttyTheme.fallback
        let initial = gate.shouldApply(theme: theme, window: window, headerColor: .systemOrange)
        let repeated = gate.shouldApply(theme: theme, window: window, headerColor: .systemOrange)
        let changed = gate.shouldApply(theme: theme, window: window, headerColor: .systemBlue)
        let cleared = gate.shouldApply(theme: theme, window: window, headerColor: nil)
        #expect(initial && !repeated && changed && cleared)
    }

    @Test func headerTextRemainsReadableOnBrightTerritoryTint() {
        let base = NSColor(red: 46/255, green: 52/255, blue: 64/255, alpha: 1)
        let foreground = NSColor(red: 216/255, green: 222/255, blue: 233/255, alpha: 1)
        let accent = NSColor(red: 217/255, green: 202/255, blue: 161/255, alpha: 1)
        let background = WorktreeVisualColors.mix(base, accent, amount: 0.36)
        for opacity in [1.0, 0.6, 0.55] {
            let color = WorktreeVisualColors.headerText(foreground, on: background, opacity: opacity)
            #expect(WorktreeVisualColors.contrast(color, background) >= 4.5)
        }
    }

    @Test func selectedTerritoryTextRemainsReadableAcrossTheRow() throws {
        let terrain = NSColor(red: 0.46, green: 0.43, blue: 0.31, alpha: 1)
        let image = NSImage(size: NSSize(width: 320, height: 104), flipped: false) { rect in
            terrain.setFill()
            rect.fill()
            return true
        }
        let preview = WorktreeSVGMap.preview(image, district: .init(motif: .forge, palette: 2, variation: 0))
        let theme = GhosttyTheme.fallback
        let colors = WorktreeVisualColors(image: preview, theme: theme, isActive: true)
        let renderer = ImageRenderer(content: Color(nsColor: terrain).overlay { ArtworkBlockBacking(showsSeparator: false) }
            .overlay(theme.foreground.opacity(0.16)).frame(width: 320, height: 104))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        for x in [16, 160, 300] {
            let background = try #require(bitmap.colorAt(x: x, y: 20))
            #expect(WorktreeVisualColors.contrast(NSColor(colors.title), background) >= 4.5)
            #expect(WorktreeVisualColors.contrast(NSColor(colors.pane), background) >= 4.5)
        }
    }

    @Test func selectedHeaderCoversWideSidebarsWithoutImageMasking() throws {
        let image = NSImage(size: NSSize(width: 320, height: 128))
        let renderer = ImageRenderer(content: WorktreeMapHeaderBackground(image: image, backgroundColor: .black)
            .frame(width: 520, height: 128).environment(\.worktreeWindowColor, .orange))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let first = try #require(bitmap.colorAt(x: 1, y: 10)?.usingColorSpace(.deviceRGB))
        let last = try #require(bitmap.colorAt(x: 519, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(abs(first.redComponent - last.redComponent) < 0.01)
        #expect(abs(first.greenComponent - last.greenComponent) < 0.01)
        #expect(first.redComponent > 0.8)
    }

    @Test("@spec LAYOUT-2.127: When composing SVG worktree artwork, the application shall illustrate the task directly using code, messages, terminals, data, or artwork rather than architectural metaphors, preserving existing color and illustration assignments during migration.")
    func taskFamiliesProduceDistinctDirectIllustrations() {
        for motif in WorktreeSVGMap.Motif.allCases {
            let drawings = (0..<3).map { WorktreeTaskIllustration.svg(motif, variant: $0) }
            #expect(Set(drawings).count == 3)
            #expect(drawings.allSatisfy { $0.contains("data-task=") })
        }
        #expect(WorktreeTaskIllustration.svg(.forge, variant: 1).contains("code-review"))
        #expect(WorktreeTaskIllustration.svg(.beacon, variant: 2).contains("remote-messages"))
        #expect(WorktreeTaskIllustration.svg(.garden, variant: 1).contains("artwork-options"))
    }
}
