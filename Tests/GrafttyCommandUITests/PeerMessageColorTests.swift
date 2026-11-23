import Foundation
import GrafttyProtocol
import ImageIO
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import GrafttyCommandUI

/// These renders also run in the iOS test target, using the same shared views.
@MainActor
@Suite(.serialized)
struct PeerMessageColorTests {
    private let start = Date(timeIntervalSince1970: 1_792_411_200)

    private func timeline(sender: String = "/repo/layout#codex") -> WorktreeTimeline {
        var history = WorktreeHistory()
        history.record(.init(text: "Check the layout.", at: start))
        history.record(WorktreeHistory.AgentResponse(id: "local", text: "I checked the layout.",
            at: start.addingTimeInterval(1), runtime: "codex", isFinal: true))
        history.record(.init(text: "<graftty-peer-message agent=\"\(sender)\">Peer checked the layout.</graftty-peer-message>",
            at: start.addingTimeInterval(2)))
        return WorktreeTimeline(history: history, brief: nil)
    }

    @Test("@spec CONTEXT-85: While Context history displays messages on Mac or mobile, the application shall use a readable purple rail marker and sender identity for incoming agent messages, retain secondary markers for local agent responses and orange for human input, and keep message text neutral.",
          arguments: [ColorScheme.light, .dark], [false, true])
    func historyDistinguishesIncomingMessages(scheme: ColorScheme, linked: Bool) async throws {
        let timeline = timeline(sender: linked ? "/repo/layout#codex" : "layout")
        var opened: [String] = []
        let image = try await render(WorktreeHistoryContent(timeline: timeline, secondary: .secondary,
            openWorktree: linked ? { opened.append($0); return true } : nil, gists: PeerMessageGistProvider { _ in nil })
            .padding(20).frame(width: 390), scheme: scheme, name: "peer-history-\(scheme)-\(linked)",
            activate: linked ? "Open worktree /repo/layout" : nil)
        #if os(iOS)
        #expect(opened == (linked ? ["/repo/layout"] : []), "The purple sender still opens its worktree")
        #endif
        #expect(image.count(in: 20..<32, matching: isPurple) > 4, "The incoming rail marker is purple")
        #expect(image.count(in: 38..<90, matching: isPurple) > 12, "Both linked and plain sender names are purple")
        #expect(image.count(in: 190..<300, matching: isPurple) == 0, "Message bodies stay neutral")
        #expect(image.count(in: 20..<32, matching: isOrange) > 4, "Human input stays orange")
        let local = WorktreeTimeline(history: {
            var history = WorktreeHistory()
            history.record(WorktreeHistory.AgentResponse(id: "local", text: "I checked the layout.", at: start, runtime: "codex"))
            return history
        }(), brief: nil)
        let localImage = try await render(WorktreeHistoryContent(timeline: local, secondary: .secondary)
            .padding(20).frame(width: 390), scheme: scheme)
        #expect(localImage.count(matching: isPurple) == 0, "Local responses do not acquire peer identity")
        #expect(image.maximumPurpleContrast(in: 38..<90) >= 4.5, "Small sender text needs at least 4.5:1 contrast")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func mapAndHeadingDistinguishIncomingFromLocal(scheme: ColorScheme) async throws {
        let timeline = timeline()
        let entries = ScrollbackMapEntry.entries(in: timeline)
        let map = ScrollbackMap(totalRows: 1000, marks: zip(timeline.events, [100, 450, 800]).map {
            .init(row: $0.1, kind: $0.0.kind == .user ? .input : .peer, eventID: $0.0.id)
        })
        let overlay = ScrollbackMapOverlay(map: map, viewport: .init(offset: 900, length: 60, total: 1000),
            entries: entries, gists: PeerMessageGistProvider { _ in nil }, availableWidth: 280, focusY: 110, scroll: { _ in })
        let image = try await render(overlay.frame(width: 280, height: 220, alignment: .topTrailing), scheme: scheme,
            name: "peer-map-\(scheme)")
        #expect(image.count(in: 250..<280, matching: isPurple) > 10, "Incoming marks are purple")
        #expect(image.count(in: 250..<280, matching: isBlue) > 4, "Local responses keep accent blue")
        #expect(image.count(in: 250..<280, matching: isOrange) > 10, "Human inputs keep orange")
        for event in timeline.events where event.kind != .user {
            let entry = try #require(entries[event.id])
            let label = try await render(ScrollbackMapLabel(entry: entry, gist: .immediate(entry.text)), scheme: scheme,
                name: "peer-heading-\(scheme)-\(event.kind)")
            #expect((label.count(matching: isPurple) > 10) == (event.kind == .agentMessage))
            if event.kind == .agentMessage { #expect(label.maximumPurpleContrast() >= 4.5) }
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func creationLabelsKeepTheirExistingIdentity(scheme: ColorScheme) async throws {
        for source in [WorktreeHistory.Origin.Source.user, .worktree, .unknown] {
            let history = WorktreeHistory(origin: .init(date: start, source: source,
                worktreePath: source == .worktree ? "/repo/main" : nil))
            let image = try await render(WorktreeHistoryContent(timeline: .init(history: history, brief: nil), secondary: .secondary,
                openWorktree: { _ in true }).padding(20).frame(width: 390), scheme: scheme)
            #expect(image.count(matching: isPurple) == 0, "Creation labels are not incoming messages")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func mergedMarksKeepInputThenIncomingPriority(scheme: ColorScheme) async throws {
        let timeline = timeline()
        let entries = ScrollbackMapEntry.entries(in: timeline)
        for includeInput in [false, true] {
            let events = timeline.events.filter { includeInput || $0.kind != .user }
            let map = ScrollbackMap(totalRows: 1000, marks: events.map {
                .init(row: 450, kind: $0.kind == .user ? .input : .peer, eventID: $0.id)
            })
            let overlay = ScrollbackMapOverlay(map: map, viewport: .init(offset: 900, length: 60, total: 1000),
                entries: entries, gists: PeerMessageGistProvider { _ in nil }, availableWidth: 280, focusY: 60, scroll: { _ in })
            let image = try await render(overlay.frame(width: 280, height: 220, alignment: .topTrailing), scheme: scheme)
            #expect((image.count(in: 250..<280, matching: isPurple) > 2) == !includeInput)
            #expect((image.count(in: 250..<280, matching: isOrange) > 2) == includeInput)
        }
    }

    private func isPurple(_ p: Pixel) -> Bool { p.r > p.g + 0.08 && p.b > p.r + 0.06 }
    private func isOrange(_ p: Pixel) -> Bool { p.r > p.g + 0.12 && p.g > p.b + 0.1 }
    private func isBlue(_ p: Pixel) -> Bool { p.g > p.r + 0.04 && p.b > p.g + 0.05 }

    private func render(_ view: some View, scheme: ColorScheme, name: String? = nil, activate: String? = nil) async throws -> Raster {
        let background = scheme == .dark ? Color(white: 0.12) : Color.white
        let content = view.fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(scheme == .dark ? Color.white : .black)
            .background(background).tint(.blue).environment(\.colorScheme, scheme)
            .environment(\.accessibilityEnabled, true)
        #if os(macOS)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: .init(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let logicalWidth = Int(host.bounds.width)
        #else
        let host = UIHostingController(rootView: content)
        host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 1000))
        host.safeAreaRegions = []
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = host.overrideUserInterfaceStyle
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        host.view.frame = CGRect(origin: .zero, size: size)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        if let activate {
            let link = try #require(accessibilityObjects(in: host.view).first { $0.accessibilityLabel == activate })
            #expect(link.accessibilityActivate())
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            #expect(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let image = try #require(rendered.cgImage)
        let logicalWidth = Int(size.width)
        #endif
        #if os(iOS)
        let renderPath: String? = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-peer-color-renders").path
        #else
        let renderPath = ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_RENDER_DIR"]
        #endif
        if let path = renderPath, let name {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = try #require(CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".png") as CFURL,
                "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        return try Raster(image: image, width: logicalWidth, background: scheme == .dark ? 0.12 : 1)
    }

    #if os(iOS)
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
    #endif

    private struct Pixel {
        let r: Double, g: Double, b: Double
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
    }

    private struct Raster {
        let width: Int
        let pixels: [Pixel]
        let background: Pixel
        init(image: CGImage, width: Int, background: Double) throws {
            self.width = width
            let height = Int(Double(image.height) * Double(width) / Double(image.width))
            self.background = Pixel(r: background, g: background, b: background)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            pixels = stride(from: 0, to: bytes.count, by: 4).map { i in
                Pixel(r: Double(bytes[i]) / 255, g: Double(bytes[i + 1]) / 255, b: Double(bytes[i + 2]) / 255)
            }
        }
        func count(in columns: Range<Int>? = nil, matching predicate: (Pixel) -> Bool) -> Int {
            pixels.enumerated().filter { (columns?.contains($0.offset % width) ?? true) && predicate($0.element) }.count
        }
        func maximumPurpleContrast(in columns: Range<Int>? = nil) -> Double {
            pixels.enumerated().filter { (columns?.contains($0.offset % width) ?? true)
                && $0.element.r > $0.element.g + 0.08 && $0.element.b > $0.element.r + 0.06 }.map { $0.element }.map {
                (max($0.luminance, background.luminance) + 0.05) / (min($0.luminance, background.luminance) + 0.05)
            }.max() ?? 0
        }
    }
}
