import Foundation
@testable import GrafttyKit

struct InstructionFilesystemFixture {
    let root: URL
    let applicationSupport: URL
    let repo: URL
    let worktree: URL

    init(prefix: String = "graftty-instr") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
        applicationSupport = root.appendingPathComponent(
            "Application Support/Graftty",
            isDirectory: true
        )
        repo = root.appendingPathComponent("repo", isDirectory: true)
        worktree = repo.appendingPathComponent(
            ".worktrees/feature-login",
            isDirectory: true
        )
        for directory in [applicationSupport, repo, worktree] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func linkedWorktree(_ key: String) -> URL {
        repo.appendingPathComponent(".worktrees/\(key)", isDirectory: true)
    }

    func makeTeam(
        linked: [(key: String, branch: String, state: WorktreeState)] = [
            ("feature-login", "feature/login", .closed)
        ],
        selectedKey: String? = nil
    ) throws -> TeamView {
        var entry = RepoEntry(path: repo.path, displayName: "acme-web")
        entry.worktrees.append(WorktreeEntry(path: repo.path, branch: "main"))
        for item in linked {
            let path = linkedWorktree(item.key)
            try FileManager.default.createDirectory(
                at: path,
                withIntermediateDirectories: true
            )
            entry.worktrees.append(WorktreeEntry(
                path: path.path,
                branch: item.branch,
                state: item.state
            ))
        }
        let selected = selectedKey.flatMap { key in
            entry.worktrees.first {
                $0.path == linkedWorktree(key).path
            }
        } ?? entry.worktrees[0]
        return TeamView.team(
            for: selected,
            in: [entry],
            teamsEnabled: true
        )!
    }

    @discardableResult
    func write(
        _ body: String,
        root checkout: URL,
        relativePath: String
    ) throws -> URL {
        let file = checkout
            .appendingPathComponent(
                InstructionStore.directoryName,
                isDirectory: true
            )
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @discardableResult
    func write(
        _ body: String,
        at checkout: URL,
        relativePath: String
    ) throws -> URL {
        try write(body, root: checkout, relativePath: relativePath)
    }
}
