/// Renders the complete, user-editable session-start hook prompt.
///
/// The built-in prompt is a Stencil template so Settings can show the exact
/// text Graftty gives the agent while still substituting the current team,
/// viewer, and worktree roster at session start.
public enum TeamInstructionsRenderer {

    public static let defaultTemplate = """
    Graftty team context.

    You are "{{ agent.name }}" on branch `{{ agent.branch }}` in repo "{{ team.repo }}".
    Worktree: `{{ agent.worktree }}`.
    {% if agent.main_worktree %}
    This is the main worktree; status events route here.
    {% else %}
    Main worktree: "{{ team.main_worktree.name }}" on `{{ team.main_worktree.branch }}` at `{{ team.main_worktree.worktree }}`. Status events route there.
    {% endif %}
    Other linked worktrees:
    {% for worktree in team.other_worktrees %}- "{{ worktree.name }}": `{{ worktree.branch }}` at `{{ worktree.worktree }}`
    {% empty %}- none
    {% endfor %}

    Other worktrees may have agents. Inbox messages arrive automatically through hook updates; do not poll.

    Team instruction files:
    - `.graftty/GRAFTTY.md` applies to every worktree. A linked worktree's key is its path relative to the main checkout's `.worktrees/`; the main checkout's key is the repository's default branch. Key `<parent>/<leaf>` uses `.graftty/<parent>/<leaf>/GRAFTTY.md`. Each ancestor's `GRAFTTY.md` applies to that worktree key and all descendants.
    - If Graftty cannot resolve the default branch, the main checkout receives only `.graftty/GRAFTTY.md` until it can.
    - Content above `## Private` is shared with peers as a role description. Content below it is delivered only to worktrees in the file's matching scope.
    - For each relative instruction path, Graftty uses the first readable regular file found in `~/Library/Application Support/Graftty/.graftty`, this worktree's `.graftty`, then the main checkout's `.graftty`. The Application Support overlay is machine-wide, so a matching name overrides that file in every repository.
    - Graftty reads current filesystem bytes and does not inspect Git; staging or committing is not required for an edit to affect the next session. Symlinks, non-regular files, and evicted iCloud placeholders are ignored.
    - Keep instruction files concise. When team structure or a specialized child role would help, suggest an appropriate instruction file; create or modify one only when authorized.

    Create an agent:
    `graftty worktree add <name> --agent <codex|claude> [--base <ref>]`
    - `--base` selects an exact locally resolvable start ref and cannot be combined with `--existing`.
    - To tune a new agent through an instruction file, create its exact-worktree `GRAFTTY.md` where its first session can see it: in Application Support, in the main checkout, or in the child's starting tree. From a linked worktree, one way to include it in the starting tree is to commit the file, then use:
      `graftty worktree add <name> --base HEAD --agent <codex|claude>`
      The new worktree inherits that file for its first session. Once the child exists, its own `.graftty` can tune later sessions without a commit. Graftty itself neither commits nor reads Git to load instructions.
    - Use `--prompt` for trusted literal text and `--prompt-stdin` for dynamic or untrusted text. The command returns the worktree's stable reply address; immediate messages are queued.

    Remove a linked worktree but keep its branch:
    `graftty worktree remove <worktree> [--force]`
    Dirty files require `--force`.

    Coordinate:
    - `graftty team list --json`; `graftty team inbox` reads the oldest unread page and marks displayed rows read after successful output. Add `--keep-unread` (`--unread` is an alias) to peek, or `--history` to inspect prior messages.
    - Inbox worktree, repository, and member selectors are diagnostic peeks and do not mark messages read.
    - Never edit Graftty state files to change inbox delivery positions; rerun the supported inbox command if advancement fails.
    - Hook-delivered messages use `<graftty-peer-message agent="<address>">`. Reply by passing that `agent` value unchanged to `graftty team send --stdin <address>`.
    - Natively delivered messages name the sender `<project>/<worktree>#<agent-id>` instead of a wrapper. Reply to `<worktree>#<agent-id>` (drop the `<project>/` prefix), or copy the exact canonical address from `graftty team list --json`. Senders named for an SCM (e.g. GitHub) or `Graftty team` are automated notices with no reply target.
    - A worktree name or path selects its default agent. `<canonical-worktree-path>#<runtime>-<12hex>` selects one exact agent; copy exact addresses from the JSON roster.
    - Send message bodies via stdin, never shell arguments. Use a fresh quoted high-entropy heredoc delimiter absent from the body:
      graftty team send --stdin <address> <<'GRAFTTY_<random>'
      <message>
      GRAFTTY_<random>
      Replace `<random>` each time; never use it literally. Quoting keeps shell syntax literal.
    - Broadcast with `graftty team broadcast --stdin` using the same pattern.

    Panes:
    - `graftty pane list [<worktree>]`; `graftty pane show <addr>`.
    - `graftty pane send` writes directly to the PTY without an inbox or consent layer; run `graftty pane send --help` first.
    """

    public static func render(team: TeamView, viewer: TeamMember) -> String {
        render(template: defaultTemplate, team: team, viewer: viewer)
            ?? ""
    }

    public static func render(
        template: String,
        team: TeamView,
        viewer: TeamMember
    ) -> String? {
        let mainWorktree = memberContext(team.mainWorktree)
        let members = team.members.map(memberContext)
        let otherWorktrees = team.members
            .filter {
                !$0.isMainWorktree &&
                $0.worktreePath != viewer.worktreePath
            }
            .map(memberContext)
        let teamContext: [String: Any] = [
            "repo": team.repoDisplayName,
            "repo_path": team.repoPath,
            "main_worktree": mainWorktree,
            "members": members,
            "other_worktrees": otherWorktrees,
        ]
        return EventBodyRenderer.renderAgentTemplate(
            template,
            agent: sessionAgentContext(viewer),
            additionalContext: ["team": teamContext]
        )
    }

    private static func sessionAgentContext(
        _ member: TeamMember
    ) -> [String: Any] {
        var context = memberContext(member)
        // Preserve the event-agent shape for older custom session templates.
        context["this_worktree"] = false
        context["other_worktree"] = false
        return context
    }

    private static func memberContext(_ member: TeamMember) -> [String: Any] {
        [
            "name": member.name,
            "worktree": member.worktreePath,
            "branch": member.branch,
            "main_worktree": member.isMainWorktree,
            "running": member.isRunning,
        ]
    }
}
