# `.graftty/` Agent Instruction Files Design

**Date:** 2026-08-02
**Status:** Approved for written-spec review

## Problem

Graftty launches agent sessions inside worktree panes and already delivers
context to them at session start through `graftty team hook <runtime>
session-start`. That context is entirely derived — team roster, main worktree,
message protocol — plus whatever the user typed into the `teamSessionPrompt`
template in Settings.

There is no way to give a *particular* worktree, or a *class* of worktrees,
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

Add `.graftty/`, a directory of plain-markdown instruction files in the
repository's main checkout, read from committed content and delivered to agent
sessions at session start.

Files are matched to worktrees by name, either exactly or by a trailing-`*`
prefix pattern. Each file may split itself into a *shared* portion visible to
every agent in the repo and a *private* portion visible only to matching
agents. Graftty never writes these files; they change through ordinary commits.

The mechanism is deliberately unopinionated about *why* worktrees are grouped.
Prefix patterns serve environment tiers (`staging-*`), task classes (`fix-*`,
`spike-*`), ownership, simulated organizations, or nothing at all — a repo can
use only exact-name files, or only the repo-wide file.

## Storage and resolution

All files live in `.graftty/` **in the repository's main checkout** — the
worktree where `worktree.path == repo.path` per `TEAM-2.3` — and resolve from
there regardless of which worktree the agent is running in.

Content is read from the **committed tree at `HEAD`**, not from the working
tree:

```
git ls-tree HEAD .graftty/          # names + blob SHAs, one call
git cat-file --batch                # all bodies, one call
```

Two subprocesses total, independent of file count.

Reading committed content rather than the filesystem is load-bearing for three
reasons:

1. It matches the propose-only authoring model below — an instruction file is in
   effect once merged, and uncommitted experiments in the main checkout are
   invisible to other worktrees' agents.
2. It is atomic. A multi-file edit can never be observed half-applied.
3. Git's tree is case-sensitive on every platform, whereas APFS is usually
   case-insensitive. A filesystem-based resolver would match `.graftty/Fix-*.md`
   against worktree `fix-auth` locally but not in CI.

The known cost: a merged instruction change reaches agents only after the main
checkout advances its `HEAD`. Keeping the main checkout current is the
operator's job. Reading `origin/main` instead was considered and rejected — it
trades a local-consistency problem for a fetch-freshness problem.

## File layout

| File | Applies to |
|---|---|
| `.graftty/GRAFTTY.md` | every worktree in the repo |
| `.graftty/<prefix>*.md` | worktrees whose name matches the prefix |
| `.graftty/<name>.md` | exactly the worktree named `<name>` |

An exact-name file is a pattern with no wildcard, so there is one matching rule
rather than two.

**Patterns are exact or trailing-`*` only.** General globbing was rejected: a
pattern like `*-vector-db` has no coherent specificity ranking against
`research-*`, and prefix matching covers the grouping cases without the
ambiguity.

**Matching target** is `WorktreeNameSanitizer(worktree.branch)` — the same value
`TEAM-2.2` uses for team member names — with `/` flattened to `-`. Branch
`research/vector-db` therefore matches `research-*` and has the exact-name file
`.graftty/research-vector-db.md`. Flattening keeps `.graftty/` a single flat
listable directory rather than a tree mirroring branch namespaces.

**Reserved and skipped**, each logged:

- the name `GRAFTTY` (reserved for the repo-wide file)
- any path nested below `.graftty/` — names are `/`-flattened, so a nested file
  could never match
- any filename containing `*` in a position other than immediately before `.md`

## Shared and private portions

Within any instruction file, the first heading at any level whose text is
exactly `Private` (case-insensitive) splits the file:

```markdown
Instructions above the marker are shared: every agent in the repo
sees this, so it is the right place for what other worktrees need
to know in order to coordinate with this one.

## Private

Instructions below the marker go only to agents whose worktree
matches this file's pattern.
```

A file with no such heading is **entirely shared**. That default is deliberate:
the failure mode is a longer prompt, which is easy to notice and fix, rather
than an instruction set that silently never appears anywhere.

`GRAFTTY.md` reaches every agent regardless, so the marker has no effect there.

A file that opens with the marker has no shared portion; the roster renders it
with a no-shared-instructions note.

Splitting inside one file rather than using two files per pattern keeps the two
halves from drifting in separate commits, and makes a review diff show at a
glance whether a change alters what other worktrees rely on (above the line) or
only the matching worktrees' own method (below it).

## Composition

An agent's own instruction stack is concatenated in this order:

1. `.graftty/GRAFTTY.md`
2. each matching pattern in **ascending prefix length** — shorter, more general
   prefixes first
3. the exact-name file, which by construction has the longest prefix and
   therefore lands last

Within a file, the shared portion precedes the private portion. Later sections
may override earlier prose; the ordering rule exists so that override direction
is predictable.

A worktree matching several patterns (`research-*` and `research-vector-*`)
receives all of them, ordered by that rule.

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

- **Your instructions** — the agent's own stack, concatenated verbatim,
  including both the shared and private portions of its own files.
- **Other worktrees** — folded into the roster `TeamInstructionsRenderer`
  already builds. Each entry keeps its existing name, branch, path, and running
  status, and gains the shared portion of the pattern and exact-name files
  matching it. `GRAFTTY.md` is excluded from roster entries: it applies to every
  worktree and already appears once in the reader's own stack.
- **Unmatched patterns** — instruction files whose pattern currently matches no
  worktree are listed by pattern with their shared portion, as plain
  discoverability. No suggested command; what to do about them is the reader's
  call.

If `.graftty/` is absent or empty at `HEAD`, the section is omitted entirely and
behavior is unchanged for repos that have not opted in.

### Relationship to `teamSessionPrompt`

Instruction content is **not** interpolated into the user's session template.
`TEAM-3.3` currently guarantees that the rendered `teamSessionPrompt` is the
complete session context and that a blanked template suppresses it. That
guarantee is amended to scope to the *team context section only*. Instructions
become their own section, exactly as queued messages already are.

Consequently, blanking the session template no longer suppresses instructions —
deleting the files does. Existing custom templates keep working unchanged, and
no template migration is required.

Instruction files are **plain markdown, not Stencil templates**. Template
rendering was considered and rejected: it adds a context surface, a render-
failure policy, and an escaping hazard, in exchange for interpolation that the
files do not obviously need.

### Trust

Instruction files reach an agent as repo-trusted instructions, on the same
footing as `CLAUDE.md`, because reaching the main checkout's `HEAD` required
review under the authoring model below. This is distinct from peer messages,
which the session prompt already marks as untrusted notes.

The rendered section states that other worktrees' shared instructions describe
what those worktrees do, not instructions the reader must follow, and that
coordination goes through `graftty team send`.

## Authoring

Graftty never writes `.graftty/`. Files change through ordinary commits to the
main branch, which for an agent means opening a pull request.

Direct writes into the main checkout's working tree by an agent in another
worktree were considered and rejected: they leave the main checkout dirty from a
non-obvious source, can collide with whatever the main worktree's own agent is
doing, and offer no guard against one worktree rewriting another's instructions.
The tradeoff accepted is that a worktree cannot revise its own standing brief
within a single autonomous run.

Because content is read from `HEAD`, uncommitted edits in the main checkout do
not take effect — including an agent's own in-progress edits — which keeps the
authoring model and the read model consistent.

## Failure handling and limits

The governing rule is to degrade to omission and never block session start.

| Condition | Behavior |
|---|---|
| No `.graftty/` at `HEAD`, or repo has no commits | Omit the section |
| `git` fails or exceeds a bounded timeout | Omit the section, log, proceed |
| Nested path below `.graftty/` | Skip, log |
| Filename with a non-trailing `*` | Skip, log |
| Reserved name collision | Skip, log |
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

- **`InstructionPattern`** — parses a filename into an exact-or-prefix pattern,
  matches it against a sanitized `/`-flattened worktree name, and ranks patterns
  by prefix length. No I/O.
- **`InstructionDocument`** — splits raw markdown into shared and private
  portions. No I/O.
- **`InstructionRenderer`** — turns a resolved stack plus the existing roster
  data into the session-start section text. No I/O.
- **`InstructionStore`** — performs the two git reads behind an injectable
  command runner, applies caps, and returns parsed documents keyed by pattern.

`TeamHookRenderer.sessionStart` gains an instructions parameter.
`TeamInstructionsRenderer`'s roster member context gains a shared-instructions
field.

## Specs

A new `INSTR — Agent Instruction Files` section in `SPECS.md`:

- **INSTR-1.x** — storage location, `HEAD`-committed reads, absent-directory
  behavior
- **INSTR-2.x** — filename patterns, matching against the sanitized flattened
  name, reserved and skipped names
- **INSTR-3.x** — shared/private split, default-to-shared, marker matching
- **INSTR-4.x** — composition order and specificity ranking
- **INSTR-5.x** — session-start delivery, roster shared text, unmatched pattern
  listing, team gating
- **INSTR-6.x** — failure handling, timeout, size caps

Plus an amendment to `TEAM-3.3` scoping its complete-prompt guarantee to the
team context section.

## Testing

Swift Testing throughout, per the repo convention, with `@spec` titles carrying
the EARS text.

Unit coverage on the three pure components: pattern parsing and rejection,
match and non-match against flattened names, specificity ordering across several
matching patterns, the split marker at each heading level and with no marker,
files opening with the marker, and renderer output for own-stack, roster, and
unmatched-pattern cases.

`InstructionStore` tests inject a fake command runner to cover cap truncation,
git failure, timeout, and malformed `ls-tree` output without needing a repo.

One integration test earns its keep: a temporary repo where an instruction file
is committed and then edited dirty in the working tree, asserting the agent
receives the **committed** text. That is the single behavioral proof of the
`HEAD`-reads decision, and it is the one thing unit tests with a fake runner
cannot establish.

## Non-goals

- A machine-local, uncommitted instruction tier. `.graftty/` can be gitignored
  per repo if local-only instructions are wanted; an Application Support overlay
  keyed by repo identity is deliberately deferred.
- Mid-session refresh when instructions change. Files are read at session start;
  a merged change reaches an agent on its next session.
- Any Graftty-side writing, creation, or editing UI for instruction files.
- Stencil templating within instruction files.
- Delivery to single-worktree repos or with agent teams disabled.
