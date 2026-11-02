#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite(.serialized)
@MainActor
struct WorktreeRowAlignmentTests {
    @Test("@spec IPAD-1.15: While the iPad sidebar displays a worktree, the application shall keep its heading on one line without repeating a differing branch or a retained report beneath it.")
    func headingOmitsSecondaryBranchAndReport() async throws {
        let row = WorktreePanes(path: "/repo/work", displayName: "work", repoDisplayName: "Repo",
            displayBranch: "feature/different-branch", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: WorktreeRowContent(worktree: row, theme: nil,
            isActive: false, isOpening: false, attentionCount: 0)
            .frame(width: 260).environment(\.accessibilityEnabled, true))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let labels = accessibilityObjects(in: host.view).compactMap(\.accessibilityLabel)
        #expect(labels.contains(row.displayName))
        #expect(!labels.contains(row.displayBranch))
    }

    @Test("@spec IOS-9.16: While a mobile worktree row is creating, deleting, or opening, the application shall center its progress indicator beside the primary title without moving the title baseline or enlarging the row.", arguments: [WorktreeWireState.creating, .deleting, .running], [false, true])
    func progressAlignsWithTitle(state: WorktreeWireState, secondaryLine: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let row = WorktreePanes(path: "/repo/feature", displayName: "fix-mobile-worktree-ui", repoDisplayName: "Graftty",
            displayBranch: secondaryLine ? "feature-branch" : "fix-mobile-worktree-ui", state: state,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: secondaryLine ? .init(id: "feature", projectID: "repo",
                brief: WorktreeBrief(recap: .init(title: "Fix Mobile worktree creation",
                    context: "Keep the creating indicator beside the worktree title even with a retained two-line brief.",
                    completed: "Traced the row layout.", next: "Verify its alignment."), at: .now), emoji: "📱") : nil)
        func content(_ row: WorktreePanes, opening: Bool) -> some View {
            WorktreeRowContent(worktree: row, theme: nil,
                isActive: false, isOpening: opening, attentionCount: 0)
                .background(RowBoundsMarker())
                .padding(.horizontal, 20).frame(width: 390)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityElement(children: .contain).environment(\.accessibilityEnabled, true)
        }
        let host = UIHostingController(rootView: content(row, opening: state == .running))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var spinner: UIActivityIndicatorView?
        var title: NSObject?
        for _ in 0..<100 {
            host.view.layoutIfNeeded()
            let objects = accessibilityObjects(in: host.view)
            spinner = objects.compactMap { $0 as? UIActivityIndicatorView }.first
            title = objects.first { $0.accessibilityLabel == row.displayName }
            if spinner != nil, title != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let activity = try #require(spinner)
        let titleFrame = try #require(title).accessibilityFrame
        #expect(titleFrame.height > 0)
        let bounds = try #require(accessibilityObjects(in: host.view).compactMap { $0 as? RowBoundsView }.first)
        let rowHeight = bounds.bounds.height
        let indicatorFrame = activity.convert(activity.bounds, to: nil)
        #expect(abs(indicatorFrame.midY - titleFrame.midY) < 3,
            "Spinner center \(indicatorFrame.midY) must match title center \(titleFrame.midY)")
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-worktree-ui-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: directory.appendingPathComponent("row-\(state)-\(secondaryLine).png"))
        let reference = WorktreePanes(path: row.path, displayName: row.displayName, repoDisplayName: row.repoDisplayName,
            displayBranch: row.displayBranch, state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: row.sidebar)
        host.rootView = content(reference, opening: false)
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutIfNeeded()
        let normalBounds = try #require(accessibilityObjects(in: host.view).compactMap { $0 as? RowBoundsView }.first)
        let normalImage = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        // UIKit can merge the only accessible Text into its row when the
        // decorative identity replaces the spinner. Its accessibility frame
        // then covers the row, not the glyphs. Compare the rendered title area.
        let localTitle = host.view.convert(titleFrame, from: window.screen.coordinateSpace)
        let rowFrame = normalBounds.convert(normalBounds.bounds, to: host.view)
        let titleRegion = CGRect(x: localTitle.minX, y: rowFrame.minY,
            width: localTitle.width, height: rowFrame.height)
        func titlePixels(_ image: UIImage) throws -> Data {
            let region = titleRegion.applying(CGAffineTransform(scaleX: image.scale, y: image.scale)).integral
            let crop = try #require(image.cgImage?.cropping(to: region))
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            return Data(pixels)
        }
        #expect(try titlePixels(image) == titlePixels(normalImage))
        #expect(abs(normalBounds.bounds.height - rowHeight) < 1)
    }

    private func accessibilityObjects(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], pending = [root], seen: Set<ObjectIdentifier> = []
        while let object = pending.popLast(), result.count < 4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            pending.append(contentsOf: (object.accessibilityElements ?? []).compactMap { $0 as? NSObject })
            pending.append(contentsOf: (object.automationElements ?? []).compactMap { $0 as? NSObject })
            for index in 0..<max(0, min(object.accessibilityElementCount(), 128)) {
                if let child = object.accessibilityElement(at: index) as? NSObject { pending.append(child) }
            }
        }
        return result
    }
}
private final class RowBoundsView: UIView {}

private struct RowBoundsMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> RowBoundsView { RowBoundsView() }
    func updateUIView(_ view: RowBoundsView, context: Context) {}
}
#endif
