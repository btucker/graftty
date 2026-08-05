import Testing
import Foundation
@testable import GrafttyKit

@Suite("SidebarWorktreeHierarchy")
struct SidebarWorktreeHierarchyTests {
    @Test("@spec LAYOUT-2.32: When at least two linked worktrees beneath `<repo>/.worktrees` share a directory component in their relative names, the sidebar shall collect them beneath a recursively expandable folder row for that component and label each worktree relative to that folder. If fewer than two worktrees share a component, the sidebar shall render the worktree ungrouped with its full relative name.")
    func groupsSharedManagedPrefixesButPreservesSingletonContext() {
        let main = WorktreeEntry(path: "/repo", branch: "main")
        let lead = WorktreeEntry(path: "/repo/.worktrees/research/lead", branch: "research/lead")
        let notes = WorktreeEntry(path: "/repo/.worktrees/research/notes", branch: "research/notes")
        let solo = WorktreeEntry(path: "/repo/.worktrees/design/prototype", branch: "design/prototype")

        let nodes = SidebarWorktreeHierarchy.nodes(
            for: [main, lead, notes, solo],
            inRepoAtPath: "/repo",
            defaultBranch: "main"
        )

        #expect(nodes == [
            .worktree(main, displayName: "main"),
            .folder(
                path: "research",
                name: "research",
                children: [
                    .worktree(lead, displayName: "lead"),
                    .worktree(notes, displayName: "notes"),
                ]
            ),
            .worktree(solo, displayName: "design/prototype"),
        ])
        #expect(SidebarWorktreeHierarchy.parentFolderPaths(in: nodes) == [
            lead.id: "research",
            notes.id: "research",
        ])
    }

    @Test("nested shared prefixes become nested folders")
    func recursivelyGroupsSharedManagedPrefixes() {
        let lead = WorktreeEntry(
            path: "/repo/.worktrees/research/mobile/lead",
            branch: "research/mobile/lead"
        )
        let notes = WorktreeEntry(
            path: "/repo/.worktrees/research/mobile/notes",
            branch: "research/mobile/notes"
        )

        let nodes = SidebarWorktreeHierarchy.nodes(
            for: [lead, notes],
            inRepoAtPath: "/repo",
            defaultBranch: nil
        )

        #expect(nodes == [
            .folder(
                path: "research",
                name: "research",
                children: [
                    .folder(
                        path: "research/mobile",
                        name: "mobile",
                        children: [
                            .worktree(lead, displayName: "lead"),
                            .worktree(notes, displayName: "notes"),
                        ]
                    ),
                ]
            ),
        ])
    }

    @Test("@spec LAYOUT-2.33: When at least two linked worktrees outside `<repo>/.worktrees` diverge beneath the same directory that is at least two components below the filesystem root and is neither the user's home nor an ancestor of the main checkout, the sidebar shall infer that directory as an additional expandable folder root. Worktrees without such a shared root shall remain ungrouped.")
    func groupsExternalWorktreesUnderAnInferredSharedRoot() {
        let first = WorktreeEntry(path: "/tmp/shared/one", branch: "one")
        let second = WorktreeEntry(path: "/tmp/shared/two", branch: "two")

        let nodes = SidebarWorktreeHierarchy.nodes(
            for: [first, second],
            inRepoAtPath: "/repo",
            defaultBranch: "main"
        )

        guard case .folder(_, let name, let children) = nodes.first else {
            Issue.record("expected an inferred folder")
            return
        }
        #expect(nodes.count == 1)
        #expect(name == "shared")
        #expect(children == [
            .worktree(first, displayName: "one"),
            .worktree(second, displayName: "two"),
        ])
    }

    @Test("separate external locations infer separate roots")
    func infersMultipleExternalRoots() {
        let lead = WorktreeEntry(path: "/alt/research/lead", branch: "lead")
        let notes = WorktreeEntry(path: "/alt/research/notes", branch: "notes")
        let sketch = WorktreeEntry(path: "/else/design/sketch", branch: "sketch")
        let prototype = WorktreeEntry(path: "/else/design/prototype", branch: "prototype")

        let nodes = SidebarWorktreeHierarchy.nodes(
            for: [lead, notes, sketch, prototype],
            inRepoAtPath: "/repo",
            defaultBranch: "main"
        )

        #expect(nodes.count == 2)
        guard case .folder(_, let firstName, _) = nodes[0],
              case .folder(_, let secondName, _) = nodes[1] else {
            Issue.record("expected two inferred folders")
            return
        }
        #expect(firstName == "research")
        #expect(secondName == "design")
    }

    @Test("colliding inferred root suffixes do not duplicate the filesystem slash")
    func inferredRootLabelsDoNotDuplicateFilesystemSlash() {
        let shortFirst = WorktreeEntry(path: "/a/shared/one", branch: "one")
        let shortSecond = WorktreeEntry(path: "/a/shared/two", branch: "two")
        let longFirst = WorktreeEntry(path: "/x/a/shared/red", branch: "red")
        let longSecond = WorktreeEntry(path: "/x/a/shared/blue", branch: "blue")

        let nodes = SidebarWorktreeHierarchy.nodes(
            for: [shortFirst, shortSecond, longFirst, longSecond],
            inRepoAtPath: "/repo",
            defaultBranch: "main"
        )

        guard nodes.count == 2,
              case .folder(_, let shortName, _) = nodes[0],
              case .folder(_, let longName, _) = nodes[1] else {
            Issue.record("expected two disambiguated inferred roots")
            return
        }
        #expect(shortName == "/a/shared")
        #expect(longName == "x/a/shared")
    }

    @Test("a broad ancestor shared with the main checkout is not inferred")
    func doesNotInferMainCheckoutAncestor() {
        let first = WorktreeEntry(path: "/Users/me/alpha/one", branch: "one")
        let second = WorktreeEntry(path: "/Users/me/beta/two", branch: "two")

        let nodes = SidebarWorktreeHierarchy.nodes(
            for: [first, second],
            inRepoAtPath: "/Users/me/projects/repo",
            defaultBranch: "main"
        )

        #expect(nodes == [
            .worktree(first, displayName: "one"),
            .worktree(second, displayName: "two"),
        ])
    }

    @Test("Claude and Codex default location shapes infer roots without vendor checks")
    func infersClaudeAndCodexDefaultLocationShapes() {
        let claudeLead = WorktreeEntry(
            path: "/repo/.claude/worktrees/lead",
            branch: "worktree-lead"
        )
        let claudeNotes = WorktreeEntry(
            path: "/repo/.claude/worktrees/notes",
            branch: "worktree-notes"
        )
        let claudeNodes = SidebarWorktreeHierarchy.nodes(
            for: [claudeLead, claudeNotes],
            inRepoAtPath: "/repo",
            defaultBranch: "main"
        )

        let codexLead = WorktreeEntry(
            path: "/Users/person/.codex/worktrees/task-a/project",
            branch: "(detached)"
        )
        let codexNotes = WorktreeEntry(
            path: "/Users/person/.codex/worktrees/task-b/project",
            branch: "(detached)"
        )
        let codexNodes = SidebarWorktreeHierarchy.nodes(
            for: [codexLead, codexNotes],
            inRepoAtPath: "/Users/person/projects/project",
            defaultBranch: "main"
        )

        guard case .folder(_, let claudeRoot, _) = claudeNodes.first,
              case .folder(_, let codexRoot, let codexChildren) = codexNodes.first else {
            Issue.record("expected inferred Claude and Codex roots")
            return
        }
        #expect(claudeRoot == "worktrees")
        #expect(codexRoot == "worktrees")
        #expect(codexChildren == [
            .worktree(codexLead, displayName: "task-a/project"),
            .worktree(codexNotes, displayName: "task-b/project"),
        ])
    }

    @Test("the user home directory is too broad to infer as a root")
    func doesNotInferUserHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let first = WorktreeEntry(path: "\(home)/alpha/one", branch: "one")
        let second = WorktreeEntry(path: "\(home)/beta/two", branch: "two")

        let nodes = SidebarWorktreeHierarchy.nodes(
            for: [first, second],
            inRepoAtPath: "/Volumes/projects/repo",
            defaultBranch: "main"
        )

        #expect(nodes == [
            .worktree(first, displayName: "one"),
            .worktree(second, displayName: "two"),
        ])
    }

    @Test("a worktree whose name equals a folder prefix keeps its label")
    func exactPrefixWorktreeDoesNotBecomeBlankFolderChild() {
        let parent = WorktreeEntry(path: "/repo/.worktrees/research", branch: "research")
        let lead = WorktreeEntry(path: "/repo/.worktrees/research/lead", branch: "research/lead")
        let notes = WorktreeEntry(path: "/repo/.worktrees/research/notes", branch: "research/notes")

        let nodes = SidebarWorktreeHierarchy.nodes(
            for: [parent, lead, notes],
            inRepoAtPath: "/repo",
            defaultBranch: "main"
        )

        #expect(nodes == [
            .worktree(parent, displayName: "research"),
            .folder(
                path: "research",
                name: "research",
                children: [
                    .worktree(lead, displayName: "lead"),
                    .worktree(notes, displayName: "notes"),
                ]
            ),
        ])
    }
}
