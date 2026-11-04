import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

#if canImport(UIKit)
import CryptoKit
import GrafttyCommandUI
import SwiftUI
import UIKit

@MainActor
struct MobileWorktreeIdentityTests {
    private func solidPNG(_ color: UIColor, side: CGFloat) throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData())
    }

    private func project(icon: Data) -> SidebarProject {
        SidebarProject(id: "repo", repositoryID: "/repo", name: "repo",
            iconRevision: SHA256.hash(data: icon).map { String(format: "%02x", $0) }.joined())
    }

    @Test("@spec IOS-4.61: While a mobile worktree header shows a home checkout whose project image has loaded, the application shall draw that image instead of the project initials, without applying it to another project or to a linked worktree's emoji.")
    func headerWashUsesLoadedProjectImage() throws {
        let image = try solidPNG(.red, side: 8)
        func row(main: Bool, emoji: String? = nil) -> WorktreePanes {
            WorktreePanes(path: "/repo/wt", displayName: "wt", repoDisplayName: "repo", displayBranch: "wt",
                state: .running, isMainCheckout: main, prBadge: nil, stats: nil, attentionText: nil,
                layout: .leaf(sessionName: "s", title: "zsh", attentionText: nil, isBusy: false, attentionSource: nil),
                sidebar: .init(id: "wt", projectID: "repo", emoji: emoji))
        }
        func glyph(_ worktree: WorktreePanes, icons: [String: Data]) -> WorktreeHeaderWash.Glyph? {
            MobileWorktreeIdentity.wash(for: worktree, icons: icons, background: .black, isDark: true)?.glyph
        }

        #expect(glyph(row(main: true), icons: ["repo": image]) == .image(image))
        if case .initials = glyph(row(main: true), icons: ["other": image]) {} else { Issue.record("expected initials") }
        #expect(glyph(row(main: false, emoji: "🧪"), icons: ["repo": image]) == .emoji("🧪"))
    }

    @Test("@spec IOS-4.62: When a project image has loaded into the shared icon cache, the application shall draw it in the phone terminal header wash for the home checkout.")
    func terminalWashDrawsCachedProjectImage() async throws {
        let image = try solidPNG(.systemPink, side: 64)
        let project = project(icon: image)
        let cache = ProjectIconCache()
        cache.reconcile([project])
        await cache.load(for: project) { image }
        try #require(cache.icons["repo"] != nil)
        let theme = GhosttyThemeColors(backgroundRGB: .init(r: 0.16, g: 0.17, b: 0.2), foregroundRGB: .init(r: 0.9, g: 0.9, b: 0.9))
        let row = WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "repo", displayBranch: "main",
            state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "repo", projectID: "repo"))
        let renderer = ImageRenderer(content: Color.black
            .overlay(alignment: .top) {
                MobileTerminalHeaderWash(worktree: row, theme: theme).frame(height: 160)
                    .environment(\.projectIconCache, cache)
            }
            .frame(width: 390, height: 300))
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: rendered.width * rendered.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: rendered.width, height: rendered.height,
                bitsPerComponent: 8, bytesPerRow: rendered.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        }
        let pink = stride(from: 0, to: bytes.count, by: 4).filter {
            Int(bytes[$0]) > Int(bytes[$0 + 1]) + 25 && bytes[$0] > bytes[$0 + 2]
        }.count
        #expect(pink > 500, "pink pixels: \(pink)")
    }

    @Test("@spec IOS-4.63: When the selected host changes, the application shall discard the project images loaded from the previous host, whose project identifiers another host may reuse.", .timeLimit(.minutes(1)))
    func changingHostsDiscardsLoadedProjectImages() async throws {
        let suite = "project-icon-host-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostStore(storeURL: directory.appendingPathComponent("hosts.json"))
        let first = Host(label: "First", baseURL: URL(string: "https://first.invalid")!, remoteDeviceID: .generate())
        let second = Host(label: "Second", baseURL: URL(string: "https://second.invalid")!, remoteDeviceID: .generate())
        try store.add(first)
        try store.add(second)
        let state = IPadAppState(defaults: defaults)
        state.selectedHostId = first.id
        let image = try solidPNG(.systemPink, side: 64)
        let project = project(icon: image)
        let cache = ProjectIconCache()
        cache.reconcile([project])
        await cache.load(for: project) { image }
        try #require(cache.icons["repo"] != nil)
        let root = RootView(hostStore: store, gate: BiometricGate(), notifications: MobileAgentNotifications(defaults: defaults),
            appState: state, notificationIO: .init(fetch: { _ in [] }, reopen: { _, _ in }), projectIconCache: cache)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 844))
        window.rootViewController = UIHostingController(rootView: root
            .defaultAppStorage(defaults)
            .environment(\.horizontalSizeClass, .regular)
            .environment(\.scenePhase, .inactive))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        window.rootViewController?.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(cache.icons["repo"] != nil, "Mounting the host's own screens must not discard its images")

        state.selectedHostId = second.id
        for _ in 0..<100 where cache.icons["repo"] != nil {
            window.rootViewController?.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(cache.icons["repo"] == nil)
    }

    @Test("@spec IOS-4.64: If the user leaves the worktree list while a project image is loading, then the application shall still finish loading it so the screens above the list can draw it.", .timeLimit(.minutes(1)))
    func leavingTheListDoesNotAbandonAnIconFetch() async throws {
        let image = try solidPNG(.systemPink, side: 64)
        let project = project(icon: image)
        let cache = ProjectIconCache()
        cache.reconcile([project])
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let list = Task { @MainActor in
            WorktreeListContent.loadProjectIcons([project], into: cache) { _, _ in
                started.continuation.yield()
                for await _ in release.stream { break }
                return image
            }
        }
        var startedIterator = started.stream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)
        list.cancel()
        release.continuation.yield()
        for _ in 0..<100 where cache.icons["repo"] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(cache.icons["repo"] != nil)
    }
}
#endif

@MainActor
struct MobileWorktreeOverviewTests {
    @Test("@spec IOS-4.55: When the phone shows a worktree with agents, the application shall list agent cards ordered by waiting for the user, working, idle, failed, then finished, each titled by its live terminal title and showing its question or result, followed by the worktree's shells and a one-line purpose from its brief.")
    func ordersAgentsByWhoNeedsTheUser() {
        func leaf(_ session: String, _ title: String, busy: Bool = true, stop: String? = nil) -> PaneLayoutNode {
            .leaf(sessionName: session, title: title, attentionText: stop, isBusy: busy, attentionSource: stop == nil ? nil : .agentStop)
        }
        let layout: PaneLayoutNode = [
            leaf("done", "Codex"), leaf("work", "Running swift test"),
            leaf("wait", "Claude", stop: "Should I push PR 806?"), leaf("idle", "Gemini", busy: false), leaf("shell", "zsh"),
        ].dropFirst().reduce(leaf("done", "Codex")) { .split(direction: .horizontal, ratio: 0.5, left: $0, right: $1) }
        let brief = WorktreeBrief(recap: AttentionRecap(title: "Agent workspaces", context: "Make the worktree recognizable",
            completed: "", next: ""), at: Date())
        let worktree = WorktreePanes(path: "/repo/wt", displayName: "wt", repoDisplayName: "repo", displayBranch: "wt",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: layout,
            sidebar: .init(id: "wt", projectID: "repo", brief: brief),
            agents: [
                .init(id: "1", name: "Codex", provider: "codex", status: "closed", sessionName: nil, completionID: "c1",
                      result: "Merged the fix.", retainedSessionName: "done"),
                .init(id: "2", name: "Builder", provider: "codex", status: "running", sessionName: "work"),
                .init(id: "3", name: "Claude", provider: "claude", status: "running", sessionName: "wait"),
                .init(id: "4", name: "Gemini", provider: "gemini", status: "running", sessionName: "idle"),
            ])

        let overview = MobileWorktreeOverview(worktree: worktree)

        #expect(overview.agents.map(\.session) == ["wait", "work", "idle", "done"])
        #expect(overview.agents.map(\.state) == [.needsInput, .working, .idle, .finished])
        #expect(overview.agents[0].message == "Should I push PR 806?")
        #expect(overview.agents[1].title == "Running swift test")
        #expect(overview.agents[1].message == nil)
        #expect(overview.agents[3].message == "Merged the fix.")
        #expect(overview.terminals.map(\.session) == ["shell"])
        #expect(overview.purpose == "Agent workspaces. Make the worktree recognizable.")
    }
}
