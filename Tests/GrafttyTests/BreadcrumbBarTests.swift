import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
@testable import Graftty

@MainActor
struct BreadcrumbBarTests {
    @Test("@spec LAYOUT-1.3: While a worktree is selected, the application shall show its repository and worktree as a breadcrumb above the agent tabs, keeping the full branch name and filesystem path in hover help instead of the navigation label.")
    func branchDetailDoesNotCompeteWithAgentTabs() throws {
        func bar(_ branch: String) -> BreadcrumbBar {
            BreadcrumbBar(repoName: "Project", worktreeDisplayName: "analytics-dashboard", worktreeEmoji: nil,
                worktreePath: "/repo/.worktrees/analytics-dashboard", branchName: branch, isHomeCheckout: false,
                prInfo: nil, theme: .fallback, sidebarHidden: false, canGoBack: true, canGoForward: false,
                historyItems: [], currentTarget: nil, onGoBack: {}, onGoForward: {}, onSelectHistory: { _ in }, onRefreshPR: {})
        }
        func render(_ bar: BreadcrumbBar) throws -> Data {
            let image = try #require(ImageRenderer(content: bar.breadcrumbLabel.frame(width: 900, height: 44)).cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            if let directory = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"],
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("breadcrumb-\(bar.branchName ?? "none").png"))
            }
            return Data(pixels)
        }
        let baseline = try render(bar("main"))
        let withLongBranch = try render(bar("CARP-5794-launch-kpis-traffic-by-source"))
        // Compare the identity label; native glass controls vary with their backdrop.
        // CoreGraphics can round an antialiased channel by one level between renders.
        #expect(baseline.count == withLongBranch.count)
        #expect(zip(baseline, withLongBranch).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        #expect(bar("main").currentLocationAccessibilityValue.contains("Branch main"))
        #expect(bar("main").currentLocationHelp == "/repo/.worktrees/analytics-dashboard\nBranch main")
    }

    @Test("@spec LAYOUT-1.6: When the breadcrumb displays a selected worktree, the application shall show its project icon for the home checkout or its assigned emoji for a linked worktree before its name, using the remote snapshot identity without falling back to a local worktree identity.")
    func selectedWorktreeEmoji() {
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🌲", remoteWorktree: nil) == "🌲")
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: nil, remoteWorktree: nil) == nil)

        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🌲", remoteWorktree: remote(emoji: "🚀")) == "🚀")
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🌲", remoteWorktree: remote(emoji: nil)) == nil)
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🌲", remoteWorktree: remote(emoji: nil, hasSidebar: false)) == nil)
    }

    @Test func homeHeaderRendersCurrentProjectInsteadOfStoredEmoji() throws {
        func bar(home: Bool, emoji: String?, initials: String) -> BreadcrumbBar {
            BreadcrumbBar(repoName: "Project", worktreeDisplayName: "root", worktreeEmoji: emoji,
                worktreePath: "/repo", branchName: "release", isHomeCheckout: home, prInfo: nil,
                theme: .fallback, sidebarHidden: false, canGoBack: false, canGoForward: false,
                historyItems: [], currentTarget: nil, onGoBack: {}, onGoForward: {}, onSelectHistory: { _ in },
                onRefreshPR: {}, project: SidebarProject(id: "project", repositoryID: "/repo", name: "Project", initials: initials))
        }
        func render(_ bar: BreadcrumbBar) throws -> Data {
            let renderer = ImageRenderer(content: bar.frame(width: 600, height: 44))
            let image = try #require(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return Data(pixels)
        }
        #expect(bar(home: true, emoji: "🐸", initials: "PR").iconIdentity == .project)
        #expect(bar(home: true, emoji: nil, initials: "PR").identityView.identity == .project)
        #expect(bar(home: true, emoji: "🐸", initials: "PR").identityView.project.displayInitials == "PR")
        #expect(bar(home: true, emoji: "🐸", initials: "NEW").identityView.project.displayInitials == "NEW")
        #expect(try render(bar(home: true, emoji: "🐸", initials: "PR"))
            != render(bar(home: true, emoji: "🐸", initials: "NEW")))
        #expect(bar(home: false, emoji: "🚀", initials: "PR").iconIdentity == .emoji("🚀"))
        let home = remote(emoji: "🐸", isMainCheckout: true)
        #expect(BreadcrumbBar.selectedWorktreeEmoji(localEmoji: "🚀", remoteWorktree: home) == nil)
    }

    private func remote(emoji: String?, hasSidebar: Bool = true, isMainCheckout: Bool = false) -> WorktreePanes {
        WorktreePanes(
            path: "/remote/feature", displayName: "feature", repoDisplayName: "Remote",
            displayBranch: "feature", state: .running, isMainCheckout: isMainCheckout,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: hasSidebar ? .init(id: "remote-worktree", projectID: "remote-project", emoji: emoji) : nil
        )
    }
}
