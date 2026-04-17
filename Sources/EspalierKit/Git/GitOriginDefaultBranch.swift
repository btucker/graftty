import Foundation

public enum GitOriginDefaultBranch {

    /// Resolves the origin default branch **name** for a repository — e.g.
    /// `"main"`, `"master"`, `"trunk"`. Callers construct the ref they
    /// need (`origin/<name>` for remote-tracking comparison, `<name>` for
    /// local-branch comparison) since different worktrees want different
    /// bases: the main checkout compares against `origin/<name>` to show
    /// unpushed work, while linked worktrees compare against the local
    /// `<name>` branch to show feature-branch divergence.
    ///
    /// Returns `nil` if there is no origin remote or no default branch can
    /// be identified. Local only — never hits the network. First tries
    /// `git symbolic-ref --short refs/remotes/origin/HEAD` and strips the
    /// `origin/` prefix; on failure, probes `main`, `master`, `develop` in
    /// order via `git show-ref --verify`.
    public static func resolve(repoPath: String) async throws -> String? {
        if let captured = try? await GitRunner.capture(
            args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            at: repoPath
        ), captured.exitCode == 0 {
            let trimmed = captured.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("origin/") {
                let name = String(trimmed.dropFirst("origin/".count))
                if !name.isEmpty { return name }
            } else if !trimmed.isEmpty {
                // Defensive: git returned an unexpected shape. Use the raw
                // value rather than failing outright.
                return trimmed
            }
        }

        // Probe fallback. show-ref --verify exits 0 if the ref exists, non-zero
        // otherwise. We check `refs/remotes/origin/<name>` directly so a
        // local branch of the same name doesn't false-positive.
        for candidate in ["main", "master", "develop"] {
            guard let captured = try? await GitRunner.capture(
                args: ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"],
                at: repoPath
            ) else { continue }
            if captured.exitCode == 0 { return candidate }
        }

        return nil
    }
}
