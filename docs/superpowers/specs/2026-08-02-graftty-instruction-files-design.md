# `.graftty/` Agent Instruction Files Design

**Date:** 2026-08-02
**Status:** Approved for written-spec review

## Problem

Graftty launches agent sessions inside worktree panes and already delivers
context to them at session start through `graftty team hook <runtime>
session-start`. That context is entirely derived — team roster, main worktree,
message protocol — plus whatever the user typed into the `teamSessionPrompt`
template in Settings.

There is no way to give a *particular* worktree, or a *group* of worktrees,
durable instructions of its own. Everything an agent knows about its assignment
either comes from the initial `--agent` prompt (which dies with the session),
from repo-wide `CLAUDE.md`/`AGENTS.md` (which applies to every agent everywhere,
including ones run outside Graftty), or from a human retyping it.

The gap matters most for long-lived worktrees that persist across many sessions
and many tasks. A worktree that exists to run research loops, or to hold a
staging environment, or to own docs, has a standing brief. That brief should
survive session restarts, survive the worktree being deleted and recreated, and
be visible to the other worktrees' agents that need to coordinate with it.

## Decision

Add `.graftty/`, a directory of plain-markdown instruction files read from
committed content and delivered to agent sessions at session start. Shared,
group, and unmatched leaf files come from the repository's main checkout;
each active worktree's leaf comes from that worktree's own committed tree.

Files are matched to worktrees by **path**, using directory nesting for
inheritance. Each file may split itself into a *shared* portion visible to every
agent in the repo and a *private* portion visible only to the worktrees it
applies to. Graftty never writes these files; they change through ordinary
commits.

The mechanism is deliberately unopinionated about *why* worktrees are grouped.
Nesting serves environment tiers, task classes, ownership, simulated
organizations, or nothing at all — a repo can use only leaf files, or only the
repo-wide file.

## Storage and resolution

All files use the same `.graftty/` paths in Git. Their source checkout depends
on their role:

- `GRAFTTY.md`, nested group files, and leaf files matching no active worktree
  come from the main checkout's committed `HEAD`.
- Each active worktree's leaf file comes from that worktree's committed `HEAD`.
  A missing worktree leaf does not fall back to a same-named main-checkout
  file.

Content is always read from a **committed tree at `HEAD`**, never from a
working tree:

```
git ls-tree -r HEAD .graftty/       # discover main-checkout files
git show HEAD:.graftty/<path>       # read each selected main file
git show HEAD:.graftty/<leaf>       # run in each active worktree
```

One listing plus at most one read per selected file. The combined read plan is
bounded by the file-count, byte, and aggregate-time limits below.

Reading committed content rather than the filesystem is load-bearing for three
reasons:

1. Instruction changes take effect only when committed; uncommitted experiments
   remain invisible to current and peer sessions.
2. Each individual file is observed as committed content rather than through a
   partially written working-tree edit. One load does not pin a checkout's
   `HEAD` across its several Git commands.
3. Git's tree is case-sensitive on every platform, whereas APFS is usually
   case-insensitive. A filesystem-based resolver would match `.graftty/Research/`
   against key `research/…` locally but not in CI.

The known cost: a shared or group change reaches agents only after the main
checkout advances its `HEAD`. Keeping the main checkout current is the
operator's job. A leaf change instead reaches the owning worktree at its next
session as soon as it is committed there. Reading `origin/main` was considered
and rejected — it trades a local-consistency problem for a fetch-freshness
problem.

## Worktree keys

Instruction files are matched against a worktree's **key**, which is derived
from its path, not its branch.

| Worktree | Key |
|---|---|
| Under `<repo>/.worktrees/` | its path relative to that directory, e.g. `research/vector-db` |
| The main checkout (`worktree.path == repo.path`) | the repository's resolved default branch name |
| Anywhere else on disk | none — receives only `.graftty/GRAFTTY.md` |

Path keying rather than branch keying is deliberate. An agent lives inside its
worktree and can run `git checkout` at will; keying on the branch would let an
agent silently swap its own instruction set. The path is durable identity. This
also matches how the rest of the system already addresses worktrees: the inbox
routes on `worktreePath`, per-worktree state files are keyed by path, and
`AGENT-5.2` calls the canonical worktree path its stable messaging address.
`TEAM-2.2`'s branch-derived member name is a display label layered on top of
that.

The main checkout is the one exception, because its path relative to
`.worktrees/` is empty. Its key is the repository's default branch, resolved via
`RemoteBranchSnapshot.defaultBranch` falling back to `RepoEntry.defaultBranchHint`.
This is a repo-level property rather than "the branch main currently has checked
out", so it remains stable when an agent changes what is checked out there.

**If the default branch is unresolved, the main checkout receives only
`.graftty/GRAFTTY.md`.** Graftty's `SidebarWorktreeLabel` falls back to the
literal string `main` when the snapshot has not resolved; inheriting that
fallback here would load `GRAFTTY.main.md` into a repo whose default is
`master`. Loading wrong instructions is worse than loading none.

A worktree at `.worktrees/main` in a repo whose default branch is `main` would
share the main checkout's key. This is benign and nearly unreachable: a
Graftty-created worktree named `main` would require branch `main` to be checked
out in two worktrees, which git refuses. Externally created, the two simply
share a file.

## File layout

Every file in `.graftty/` is named `GRAFTTY*.md`. There are exactly two forms:

| Form | Applies to |
|---|---|
| `<dir>/GRAFTTY.md` | every worktree whose key is **beneath** `<dir>` |
| `<dir>/GRAFTTY.<leaf>.md` | the single worktree whose key is `<dir>/<leaf>` |

A worktree's own leaf file lives at its **parent** level. For key
`research/vector-db`:

```
.graftty/GRAFTTY.md                     ← all worktrees
.graftty/research/GRAFTTY.md            ← everything under research/
.graftty/research/GRAFTTY.vector-db.md  ← just this worktree
```

For a top-level key `foo`, the chain is `.graftty/GRAFTTY.md` then
`.graftty/GRAFTTY.foo.md`.

Placing the leaf file at the parent level is what removes the leaf/group
collision. `research` as a *group* is the directory `.graftty/research/`;
`research` as a *worktree* is the file `.graftty/GRAFTTY.research.md` one level
up. Different names in different directories, so no precedence rule is needed.

`<dir>/GRAFTTY.md` covers descendants **only**, not a worktree whose key is
exactly `<dir>`. That worktree is addressed by its leaf file at the level above.
The distinction is observable only when a worktree and a group share a name,
which through Graftty's own Add Worktree flow cannot happen — the name becomes
both branch and path, and git's ref directory/file conflict rejects branches
`research` and `research/vector-db` coexisting in either creation order. It is
reachable only for externally created worktrees whose branch and path diverge.

**Skipped, each logged:** any file in `.graftty/` not matching `GRAFTTY.md` or
`GRAFTTY.<leaf>.md`, and any file whose leaf component is empty
(`GRAFTTY..md`). Leaf names containing `.` are fine — parsing anchors on the
`GRAFTTY.` prefix and `.md` suffix, so `GRAFTTY.api.v2.md` unambiguously means
leaf `api.v2`.

**Wildcard patterns were considered and rejected.** Prefix globs
(`GRAFTTY.research-*.md`) would provide grouping without namespaced names, but
they require a specificity ranking, `*`-position validation, and a rule for how
a glob match orders against a directory match. Directory depth supplies the same
grouping with ordering that falls out for free. The cost is that grouping
requires namespaced worktree names, and existing flat names get no grouping
until renamed.

## Shared and private portions

Within any instruction file, the first heading at any level whose text is
exactly `Private` (case-insensitive) splits the file:

```markdown
Instructions above the marker are shared: every agent in the repo
sees this, so it is the right place for what other worktrees need
to know in order to coordinate with this one.

## Private

Instructions below the marker go only to the worktrees this file
applies to.
```

A file with no such heading is **entirely shared**. That default is deliberate:
the failure mode is a longer prompt, which is easy to notice and fix, rather
than an instruction set that silently never appears anywhere.

`.graftty/GRAFTTY.md` reaches every agent regardless, so the marker has no
effect there.

A file that opens with the marker has no shared portion; the roster renders it
with a no-shared-instructions note.

Splitting inside one file rather than using two files per level keeps the two
halves from drifting in separate commits, and makes a review diff show at a
glance whether a change alters what other worktrees rely on (above the line) or
only the applicable worktrees' own method (below it).

## Composition

An agent's own instruction stack is the chain from root to leaf, concatenated in
path-depth order: each ancestor directory's `GRAFTTY.md`, then its own leaf
file. Within a file, the shared portion precedes the private portion.

Later sections may override earlier prose; the ordering rule exists so that
override direction is predictable. There is no specificity ranking to compute —
depth is the ordering.

## Delivery

Delivery rides the existing team session-start hook and is **team-gated as
today**: `agentTeamsEnabled` must be true and the repo must have at least two
worktrees, since `TeamView.team` requires `repo.worktrees.count >= 2`. A
single-worktree repo containing `.graftty/` receives nothing; this is a
documented limitation, not a defect.

Every agent session in a Graftty pane receives instructions — both runtimes,
whether the session was launched by `graftty worktree add --agent` or by typing
the runtime into a pane.

`TeamHookRenderer.sessionStart` gains a third section alongside the rendered
team context and the queued inbox messages:

- **Your instructions** — the agent's own chain, concatenated verbatim,
  including both the shared and private portions of its own files.
- **Other worktrees** — a separate block keyed by the same display names used
  in the `TeamInstructionsRenderer` roster, containing the shared portions of
  the files applying to each worktree.
  `.graftty/GRAFTTY.md` is excluded from roster entries: it applies to every
  worktree and already appears once in the reader's own stack.
- **Unmatched entries** — instruction files that currently apply to no worktree
  are listed by their path with their shared portion, as plain discoverability.
  No suggested command; what to do about them is the reader's call.

If no relevant checkout contains committed instruction content, the section is
omitted entirely and behavior is unchanged for repos that have not opted in. A
branch-only active leaf is sufficient to opt in before main contains
`.graftty/`.

### Relationship to `teamSessionPrompt`

Instruction content is **not** interpolated into the user's session template.
`TEAM-3.3` currently guarantees that the rendered `teamSessionPrompt` is the
complete session context and that a blanked template suppresses it. That
guarantee is amended to scope to the *team context section only*. Instructions
become their own section, exactly as queued messages already are.

Consequently, blanking the session template no longer suppresses instructions —
committing their deletion does. Existing custom templates keep working
unchanged, and no template migration is required.

Instruction files are **plain markdown, not Stencil templates**. Template
rendering was considered and rejected: it adds a context surface, a render-
failure policy, and an escaping hazard, in exchange for interpolation that the
files do not obviously need.

### Trust

Shared and group files reach an agent as repo-trusted instructions, on the same
footing as `CLAUDE.md`, because they come from the main checkout's committed
tree. A worktree's own leaf is branch-local trusted context, like other
instruction files committed on that branch.

Another worktree's shared leaf content is not an instruction to the reader. It
is explicitly framed as that worktree's self-authored role description, and the
rendered section directs coordination through `graftty team send`. This framing
is load-bearing now that a worktree can publish its role before main-branch
review.

## Authoring

The Graftty application never writes `.graftty/`. The built-in session prompt
teaches agents the file forms, asks them to keep files concise, and permits them
to suggest an appropriate file when durable structure would help. Agents create
or modify files only when the user has authorized that work.

Shared and group files change through ordinary commits to the default branch,
normally by pull request. A worktree may author its own leaf in its own checkout
and commit it on its branch; that committed leaf takes effect at the next
session without waiting to merge. Agents never need to write into another
worktree or dirty the main checkout.

Because content is read from `HEAD`, an agent's in-progress edits do not take
effect. This preserves a clear boundary between drafting a role and activating
it.

## Failure handling and limits

The governing rule is to degrade to omission and never block session start.

| Condition | Behavior |
|---|---|
| No committed instruction content in any relevant checkout | Omit the section |
| One checkout's non-timeout `git` read fails | Omit its unavailable content, log, continue with other checkouts |
| The aggregate `git` deadline expires | Omit the section, log, proceed |
| Filename not matching `GRAFTTY.md` / `GRAFTTY.<leaf>.md` | Skip, log |
| Empty leaf component (`GRAFTTY..md`) | Skip, log |
| Main checkout with unresolved default branch | Root file only, no leaf file |
| Worktree outside the repo's worktrees directory | Root file only |
| Per-file size cap exceeded | Truncate with a visible marker |
| Total stack size cap exceeded | Truncate with a visible marker |
| Several `Private` headings | First one splits; the rest are ordinary content |
| File begins with the `Private` heading | No shared portion; roster notes this |

The bounded timeout is load-bearing rather than defensive: `CLIRunner` has
historically lacked a subprocess timeout, and an unbounded `git` call on the
session-start path would hang session start rather than fail it.

Size caps follow the precedent of the 131072-byte initial-prompt cap in
`AGENT-5.1`.

## Components

Three pure units and one I/O unit, each testable in isolation:

- **`InstructionKey`** — derives a worktree's key from its path, the repo path,
  and the resolved default branch; returns none for out-of-tree worktrees. No
  I/O.
- **`InstructionChain`** — turns a key into the ordered list of file paths to
  read, and classifies a discovered filename as a group file, a leaf file, or
  skippable. No I/O.
- **`InstructionDocument`** — splits raw markdown into shared and private
  portions. No I/O.
- **`InstructionStore`** — lists main-checkout files, reads each active leaf in
  its owning checkout, applies one aggregate timeout and size budget, and
  returns main documents plus worktree-keyed leaf documents.

`TeamHookRenderer.sessionStart` gains an instructions parameter.
`InstructionSessionText` supplies the active worktree sources to the store and
the resulting audience-specific documents to `InstructionRenderer`.
`TeamInstructionsRenderer`'s built-in prompt gains the concise authoring guide.

## Specs

A new `INSTR — Agent Instruction Files` section in `SPECS.md`:

- **INSTR-1.x** — storage location, `HEAD`-committed reads, absent-directory
  behavior
- **INSTR-2.x** — worktree key derivation, including the main checkout and
  out-of-tree cases
- **INSTR-3.x** — the two filename forms, descendants-only semantics for group
  files, skipped names
- **INSTR-4.x** — shared/private split, default-to-shared, marker matching
- **INSTR-5.x** — composition order by path depth
- **INSTR-6.x** — session-start delivery, roster shared text, unmatched entry
  listing, team gating
- **INSTR-7.x** — failure handling, timeout, size caps

Plus an amendment to `TEAM-3.3` scoping its complete-prompt guarantee to the
team context section.

## Testing

Swift Testing throughout, per the repo convention, with `@spec` titles carrying
the EARS text.

Unit coverage on the three pure components: key derivation for nested,
top-level, main-checkout, unresolved-default-branch, and out-of-tree worktrees;
chain construction at several depths; filename classification including leaf
names containing dots and the rejected forms; the split marker at each heading
level, with no marker, and as the first line; and renderer output for own-stack,
roster, and unmatched-entry cases.

`InstructionStore` tests inject a fake command runner to cover checkout
selection, cap truncation, git failure, timeout, and malformed `ls-tree` output
without needing a repo.

Two integration cases earn their keep: a main-checkout instruction committed
and then edited dirty, and a leaf committed in a linked worktree but absent from
main and then edited dirty. Both assert that delivery uses the appropriate
**committed** text. These are the behavioral proofs of the `HEAD`-read decision
that a fake runner cannot establish.

## Non-goals

- A machine-local, uncommitted instruction tier. `.graftty/` can be gitignored
  per repo if local-only instructions are wanted; an Application Support overlay
  keyed by repo identity is deliberately deferred.
- Mid-session refresh when instructions change. Files are read at session start;
  a committed change in the relevant checkout reaches an agent on its next
  session.
- Any Graftty-side writing, creation, or editing UI for instruction files.
- Stencil templating within instruction files.
- Wildcard or glob patterns in filenames.
- Delivery to single-worktree repos or with agent teams disabled.
