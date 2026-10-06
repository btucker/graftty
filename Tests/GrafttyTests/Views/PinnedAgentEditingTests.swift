import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyCommandUI
@testable import Graftty

@MainActor
@Suite("Pinned agent role editing and section spacing")
struct PinnedAgentEditingTests {
    @Test("@spec INSTR-8.4: When role-file preparation finishes, the application shall revalidate the pinned worktree's identity, paths, and eligibility before selecting an editor destination, rejecting removed, relocated, or in-flight worktrees and using the default checkout for stale pinned roles.")
    func editorDestinationRejectsChangedTargetsBeforeSelection() {
        var role = WorktreeEntry(path: "/repo/.worktrees/reviewer", branch: "reviewer")
        role.isPinned = true
        let home = WorktreeEntry(path: "/repo", branch: "trunk")
        var repo = RepoEntry(path: home.path, displayName: "Repo", worktrees: [home, role])
        let destination: (AppState) -> String? = { SidebarMenuVisibility.roleEditorDestination(worktree: role, repo: repo, state: $0) }
        #expect(destination(AppState(repos: [repo])) == role.path)
        #expect(destination(AppState()) == nil)
        var changed = repo
        changed.worktrees.removeLast()
        #expect(destination(AppState(repos: [changed])) == nil)
        changed = repo
        changed.worktrees[1].path = "/moved/reviewer"
        #expect(destination(AppState(repos: [changed])) == nil)
        changed = repo
        changed.worktrees[1].state = .deleting
        #expect(destination(AppState(repos: [changed])) == nil)
        changed = repo
        changed.worktrees[1].isPinned = false
        #expect(destination(AppState(repos: [changed])) == nil)
        role.state = .stale
        repo.worktrees[1] = role
        #expect(destination(AppState(repos: [repo])) == home.path)
    }

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

    @Test("@spec LAYOUT-2.112: While the sidebar displays Pinned Agents, the application shall align its disclosure and title with worktree rows and use compact spacing when the section begins the list.")
    func sectionHeaderHasDeliberateSpacing() throws {
        let header = SidebarWorktreeSectionHeader("Pinned Agents", isCollapsed: .constant(false))
        let host = NSHostingController(rootView: header)
        #expect(host.sizeThatFits(in: CGSize(width: 300, height: 1000)).height == 32)
        let firstHeader = NSHostingController(rootView: SidebarWorktreeSectionHeader("Pinned Agents",
            isCollapsed: .constant(false), separatesPrecedingRows: false))
        #expect(firstHeader.sizeThatFits(in: CGSize(width: 300, height: 1000)).height == 20)
        if let directory = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"] {
            let preview = ProjectWorktreeColumn {
                SidebarWorktreeSectionHeader("Pinned Agents", isCollapsed: .constant(false), separatesPrecedingRows: false)
                previewWorktree(name: "trunk", pinned: true)
                previewWorktree(name: "release-manager", pinned: true)
                HStack { Label("Manual Order", systemImage: "arrow.up.arrow.down"); Spacer(); Label("Add worktree", systemImage: "plus") }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).frame(height: 44)
                previewWorktree(name: "Temporary task", pinned: false)
            }
            .frame(width: 300, height: 370)
            .background(Color(red: 0.16, green: 0.17, blue: 0.19))
            .environment(\.colorScheme, .dark)
            try capture(preview, name: "pinned-agents-spacing", directory: directory)
            let insets = EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0)
            let list = List {
                DisclosureGroup(isExpanded: .constant(true)) {
                    DisclosureGroup(isExpanded: .constant(true)) {
                        SidebarWorktreeSectionHeader("Pinned Agents", isCollapsed: .constant(false), separatesPrecedingRows: false).listRowInsets(insets)
                        previewWorktree(name: "trunk", pinned: true).listRowInsets(insets)
                        previewWorktree(name: "release-manager", pinned: true).listRowInsets(insets)
                        previewWorktree(name: "Temporary task", pinned: false).listRowInsets(insets)
                    } label: { Text("Repository") }
                } label: { Text("Remote Mac") }
            }
            .listStyle(.sidebar)
            .frame(width: 300, height: 370)
            .environment(\.colorScheme, .dark)
            try capture(list, name: "pinned-agents-list-spacing", directory: directory)
        }
    }

    private func capture<V: View>(_ view: V, name: String, directory: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 370)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
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
