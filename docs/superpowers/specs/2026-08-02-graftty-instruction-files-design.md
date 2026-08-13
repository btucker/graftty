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

Add `.graftty/`, a directory of plain-markdown instruction files read directly
from a filesystem overlay and delivered to agent sessions at session start.
For each relative file, machine-wide Application Support can override the
current worktree, which can override the main checkout.

Files are matched to worktrees by **path**, using directory nesting for
inheritance. Each file may split itself into a *shared* portion visible to every
agent in the repo and a *private* portion visible only to the worktrees it
applies to. Graftty never writes these files and never consults Git while
loading them; current filesystem bytes take effect at the next session start.

The mechanism is deliberately unopinionated about *why* worktrees are grouped.
Nesting serves environment tiers, task classes, ownership, simulated
organizations, or nothing at all — a repo can use only exact-worktree files,
only inherited files, or only the repo-wide file.

## Storage and resolution

All sources use the same `.graftty/`-relative paths. For each path, Graftty
uses the first readable, materialized regular file in this order:

1. `~/Library/Application Support/Graftty/.graftty/`
2. the session viewer's current worktree `.graftty/`
3. the repository's main checkout `.graftty/`

Resolution is **per relative path**, not per directory. A sparse Application
Support overlay can replace `GRAFTTY.md` without hiding a nested file that
exists only in the main checkout. Identical roots (the main checkout viewing
itself) are deduplicated.

Application Support is deliberately machine-wide rather than repo-scoped.
This makes it useful for personal policy and emergency overrides, but creates
an equally deliberate collision domain: a matching relative path overrides
that file in every repository. The built-in session prompt calls this out.

Only materialized regular files and directories participate. Graftty uses
`lstat` and no-follow opens, rejects symlinks and special files, and checks
`SF_DATALESS` before reading so an evicted iCloud/File Provider placeholder
does not synchronously trigger hydration. Discovery and reads run away from
the main actor. File-count and byte limits bound the resulting prompt.

### Configuring a child before launch

An agent configures a child by creating the child's exact-worktree file somewhere the first
session can resolve it: Application Support, the main checkout, or the child's
starting tree. A linked-worktree agent can choose to include the file in the
starting tree by committing it and creating the child from that exact commit:

```
graftty worktree add <name> --base HEAD --agent <codex|claude>
```

The CLI resolves `HEAD` in the caller's worktree before creating the new
branch, so Git happens to copy that file into the child. Graftty itself neither
commits nor reads Git: the child's session reads the resulting filesystem file.
Once the child exists, editing its own `.graftty/` changes later sessions
without a commit. A main-checkout copy is another useful pre-launch path: a
new child that lacks its own copy falls back to the main checkout immediately,
including when that main file is uncommitted.

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
fallback here would load `main/GRAFTTY.md` into a repo whose default is
`master`. Loading wrong instructions is worse than loading none.

A worktree at `.worktrees/main` in a repo whose default branch is `main` would
share the main checkout's key. This is benign and nearly unreachable: a
Graftty-created worktree named `main` would require branch `main` to be checked
out in two worktrees, which git refuses. Externally created, the two simply
share a file.

## File layout

Every instruction file is named exactly `GRAFTTY.md`. Its containing directory
is the worktree key where its scope begins, and the file applies to that key and
all descendants. For key `research/vector-db`:

```
.graftty/GRAFTTY.md                     ← all worktrees
.graftty/research/GRAFTTY.md            ← research and descendants
.graftty/research/vector-db/GRAFTTY.md  ← research/vector-db and descendants
```

For a top-level key `foo`, the chain is `.graftty/GRAFTTY.md` then
`.graftty/foo/GRAFTTY.md`.

This deliberately makes scope hierarchical: `research/GRAFTTY.md` applies to a
worktree keyed `research` as well as `research/*`. Git can technically place a
linked worktree inside another linked worktree, but the parent sees the child
directory as untracked, and Graftty's normal branch-backed creation cannot use
both `research` and `research/vector-db` branch names because Git rejects the
ref file/directory collision. The natural inheritance rule is preferable to a
second filename form for that pathological arrangement.

**Skipped, each logged:** any regular file in `.graftty/` whose name is neither
exactly `GRAFTTY.md` nor the legacy `GRAFTTY.<leaf>.md` form.

For upgrade compatibility with v0.4.x, `GRAFTTY.<leaf>.md` remains a read-only
alias for `<leaf>/GRAFTTY.md` at the same directory level. Discovery stores it
under the canonical hierarchical path. When both forms exist in one overlay
root, the hierarchical file wins and the load emits a diagnostic naming the
preferred and shadowed absolute paths. The loader never merges or deletes the
legacy file: the user must reconcile any content that still matters before
deleting it. Across roots, the normal Application Support/current-worktree/
main-checkout precedence still wins. The built-in prompt and provider skill
teach only the hierarchical form.

**Wildcard patterns were considered and rejected.** They require a specificity
ranking, pattern validation, and a rule for how a wildcard orders against a
directory match. Directory depth supplies grouping with ordering that falls out
for free. The cost is that grouping requires namespaced worktree names, and
existing flat names get no grouping until renamed.

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
halves from drifting in separate edits, and makes a review diff show at a
glance whether a change alters what other worktrees rely on (above the line) or
only the applicable worktrees' own method (below it).

## Composition

An agent's own instruction stack is the chain from root to its exact key,
concatenated in path-depth order: the root and each successive directory's
`GRAFTTY.md`. Within a file, the shared portion precedes the private portion.

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

If no overlay root contains readable instruction content, the section is
omitted entirely and behavior is unchanged for repos that have not opted in.
A viewer-only leaf is sufficient to opt that worktree in before main contains
`.graftty/`.

### Relationship to `teamSessionPrompt`

Instruction content is **not** interpolated into the user's session template.
`TEAM-3.3` currently guarantees that the rendered `teamSessionPrompt` is the
complete session context and that a blanked template suppresses it. That
guarantee is amended to scope to the *team context section only*. Instructions
become their own section, exactly as queued messages already are.

Consequently, blanking the session template no longer suppresses instructions —
removing them from every applicable overlay does. Existing custom templates keep working
unchanged, and no template migration is required.

Instruction files are **plain markdown, not Stencil templates**. Template
rendering was considered and rejected: it adds a context surface, a render-
failure policy, and an escaping hazard, in exchange for interpolation that the
files do not obviously need.

### Trust

Files in these roots reach the matching agent as local trusted instructions,
on the same footing as other workspace instruction files. The higher roots are
not intrinsically more trustworthy; precedence only selects which bytes win.
Application Support is user-machine policy, the current-worktree tier is
editable by that worktree, and the main-checkout tier is the shared fallback.

Another worktree's shared content is not an instruction to the reader. It
is explicitly framed as that worktree's self-authored role description, and the
rendered section directs coordination through `graftty team send`. Under the
filesystem model the org chart is the viewer's resolved overlay: it does not
reach into peer worktrees to fetch their current bytes.

## Authoring

The Graftty application never writes `.graftty/`. The built-in session prompt
teaches agents the file forms, asks them to keep files concise, and permits them
to suggest an appropriate file when durable structure would help. Agents create
or modify files only when the user has authorized that work.

Repository files may still change through ordinary reviewed commits, but that
is an authoring policy rather than a loader requirement. A worktree may author
its own exact-worktree file in its own checkout and the current bytes take effect in its next
session. To configure a not-yet-created child, an agent uses Application
Support, the main checkout, or arranges for the file to exist in the child's
starting tree. Agents never need to write into an existing peer worktree.

## Failure handling and limits

The governing rule is to degrade to omission and never block session start.

| Condition | Behavior |
|---|---|
| No readable instruction content in any overlay root | Omit the section |
| Higher-precedence candidate is absent, unreadable, or unsafe | Continue to the same path in the next root |
| Symlink, FIFO, socket, device, or other non-regular entry | Skip without opening it |
| Evicted iCloud/File Provider (`SF_DATALESS`) entry | Skip without reading it |
| The aggregate filesystem load exceeds one second | Omit the section without awaiting the late I/O |
| Filename neither `GRAFTTY.md` nor legacy `GRAFTTY.<leaf>.md` | Skip, log |
| Canonical and legacy forms for one scope in one root | Use the canonical hierarchical file and emit a diagnostic naming both absolute paths; never merge or delete either file |
| Main checkout with unresolved default branch | Root file only, no keyed file |
| Worktree outside the repo's worktrees directory | Root file only |
| Per-file size cap exceeded | Truncate with a visible marker |
| Total stack size cap exceeded | Truncate with a visible marker |
| The remaining total budget cannot fit the truncation marker | Omit that file rather than emit an unmarked fragment |
| Several `Private` headings | First one splits; the rest are ordinary content |
| File begins with the `Private` heading | No shared portion; roster notes this |

Size caps follow the precedent of the 131072-byte initial-prompt cap in
`AGENT-5.1`.

## Components

Three pure units and one I/O unit, each testable in isolation:

- **`InstructionKey`** — derives a worktree's key from its path, the repo path,
  and the resolved default branch; returns none for out-of-tree worktrees. No
  I/O.
- **`InstructionChain`** — turns a key into the ordered list of hierarchical
  file paths to read. **`InstructionFile`** classifies a discovered path as a
  canonical scope, legacy alias, or skippable. No I/O.
- **`InstructionDocument`** — splits raw markdown into shared and private
  portions. No I/O.
- **`InstructionStore`** — discovers valid paths across the three filesystem
  roots, resolves each path by precedence, rejects unsafe or unmaterialized
  entries, and applies file-count and byte budgets.

`TeamHookRenderer.sessionStart` gains an instructions parameter.
`InstructionSessionText` supplies the viewer worktree, main checkout, and
viewer-first path preferences to the store, then sends the resolved documents
to `InstructionRenderer`.
`TeamInstructionsRenderer`'s built-in prompt gains the concise authoring guide.

## Specs

A new `INSTR — Agent Instruction Files` section in `SPECS.md`:

- **INSTR-1.x** — filesystem roots, per-path precedence, current-byte reads,
  absent-directory behavior
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
chain construction at several depths; canonical and legacy filename
classification, same-root preference, and rejected forms; the split marker at each heading
level, with no marker, and as the first line; and renderer output for own-stack,
roster, and unmatched-entry cases.

`InstructionStore` tests create isolated filesystem roots to cover per-path
precedence, current uncommitted bytes, absent roots, malformed names, caps and
ragged cap remainders, the one-second deadline, ancestor and final-component
symlink rejection, case-distinct overlay paths, FIFO rejection, and the
`SF_DATALESS` materialization predicate.
Session rendering tests use the same real-filesystem behavior to prove that a
creating child receives its current-worktree instructions in its first session and
that viewer paths win prompt limits.

## Non-goals

- A repo-scoped Application Support namespace. The Application Support overlay
  is intentionally machine-wide; avoiding collisions is the author's job.
- Mid-session refresh when instructions change. Files are read at session start;
  a filesystem change in the resolved overlay reaches an agent on its next session.
- Any Graftty-side writing, creation, or editing UI for instruction files.
- Stencil templating within instruction files.
- Wildcard or glob patterns in filenames.
- Delivery to single-worktree repos or with agent teams disabled.
