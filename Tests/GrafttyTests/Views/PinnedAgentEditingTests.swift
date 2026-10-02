import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyCommandUI
@testable import Graftty

@MainActor
@Suite("Pinned agent role editing and section spacing")
struct PinnedAgentEditingTests {
    @Test("@spec INSTR-8.2: When the user chooses Edit Role Instructions on a pinned local worktree, the application shall use the same configured editor routing as terminal file links, opening a CLI editor in a new pane in that worktree, and shall offer the action for the default checkout and externally located pinned worktrees.")
    func pinnedRoleUsesConfiguredEditorAndOffersMenuAcrossPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("role editor '\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("GRAFTTY.md")
        try "# Role\n".write(to: file, atomically: true, encoding: .utf8)
        let defaultsName = "graftty-role-editor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("cli", forKey: EditorPreference.Keys.kind)
        defaults.set("nvim -f", forKey: EditorPreference.Keys.cliCommand)
        let manager = TerminalManager(socketPath: directory.appendingPathComponent("control.sock").path)
        manager.editorPreference = EditorPreference(defaults: defaults, shellEnvProbe: EmptyEditorProbe())
        let pane = PaneSlotID()
        var opened: [(PaneSlotID, String)] = []
        manager.onOpenInEditorPane = { opened.append(($0, $1)) }
        #expect(manager.openURL(file.absoluteString, from: pane))
        #expect(opened.count == 1)
        if let request = opened.first {
            #expect(request.0 == pane)
            #expect(request.1 == EditorOpenRouter.buildCliCommand(editor: "nvim -f", path: file.path, line: nil))
        }
        let repo = RepoEntry(path: "/repo", displayName: "Repo")
        for path in [repo.path, "/repo/.worktrees/reviewer", "/outside/reviewer"] {
            var worktree = WorktreeEntry(path: path, branch: "role")
            worktree.isPinned = path != repo.path
            #expect(SidebarMenuVisibility.showsEditRoleInstructions(worktree: worktree, repo: repo))
            worktree.state = .creating
            #expect(!SidebarMenuVisibility.showsEditRoleInstructions(worktree: worktree, repo: repo))
        }
        #expect(!SidebarMenuVisibility.showsEditRoleInstructions(worktree: .init(path: "/repo/.worktrees/task", branch: "task"), repo: repo))
    }

    @Test("@spec LAYOUT-2.112: While the sidebar displays Pinned Agents, the application shall align its disclosure and title with worktree rows and reserve more space above the section title than below it.")
    func sectionHeaderHasDeliberateSpacing() throws {
        let header = SidebarWorktreeSectionHeader("Pinned Agents", isCollapsed: .constant(false))
        let host = NSHostingController(rootView: header)
        #expect(host.sizeThatFits(in: CGSize(width: 300, height: 1000)).height == 32)
        let firstHeader = NSHostingController(rootView: SidebarWorktreeSectionHeader("Pinned Agents",
            isCollapsed: .constant(false), separatesPrecedingRows: false))
        #expect(firstHeader.sizeThatFits(in: CGSize(width: 300, height: 1000)).height == 24)
        if let directory = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"] {
            let preview = ProjectWorktreeColumn {
                previewWorktree(name: "Temporary task", pinned: false)
                header
                previewWorktree(name: "trunk", pinned: true)
                previewWorktree(name: "release-manager", pinned: true)
            }
            .frame(width: 300, height: 290)
            .background(Color(red: 0.16, green: 0.17, blue: 0.19))
            .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: preview)
            hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 290)
            hosting.layoutSubtreeIfNeeded()
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("pinned-agents-spacing.png"))
        }
    }

    private func previewWorktree(name: String, pinned: Bool) -> some View {
        VStack(spacing: 0) {
            WorktreeRow(entry: .init(path: "/repo/.worktrees/" + name, branch: name, state: .running),
                isActive: false, displayName: name, isMainCheckout: name == "trunk",
                theme: .fallback, stats: nil, baseRef: nil, prBadge: nil, attentionStyle: nil)
                .frame(minHeight: 28)
            PaneTitleRow(title: pinned ? "Durable role" : "Working on a task", isActiveWorktree: false,
                isFocusedPane: false, isBusy: false, theme: .fallback, attentionStyle: nil, portBindings: [])
        }
        .padding(.vertical, 8)
    }

    private struct EmptyEditorProbe: ShellEnvProbe {
        func value(forName name: String) -> String? { nil }
    }
}
