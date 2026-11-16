---
name: graftty
description: Keep worktree context current and request attention explicitly.
---

# Graftty

Help the user recover the problem being solved and why it matters, where the
work stands, and whether they need to act. Graftty retains that context.
Send only what changed.

Read `graftty context show --json` at session start or after losing context.
The private file snapshot also verifies that the owning host supports updates.
If unavailable, relaunch the updated app and start a turn. Do not submit the new
shape to an older host. Legacy `graftty attention report --stdin` remains
available for old integrations.

Publish the first context as soon as you understand the task and why it
matters, before starting long work. Include `purpose` and `now` on first use:

```sh
graftty context update --stdin <<'GRAFTTY_CONTEXT_7F3A91C2'
{"purpose":{"title":"Posting model evals","context":"Model costs limit how many postings we can process."},"now":{"summary":"The cheaper model nearly matched the baseline.","next":"Evaluate the holdout."},"emoji":"🧪","emojiAlternatives":["🔬","📊"]}
GRAFTTY_CONTEXT_7F3A91C2
```

During each turn, before your final response, publish changed groups or acknowledge no change:

```sh
graftty context update --stdin <<'GRAFTTY_CONTEXT_63A2F4B1'
{"now":{"summary":"Both models passed the holdout."}}
GRAFTTY_CONTEXT_63A2F4B1
```

Use `{"unchanged":true}` by itself when nothing useful changed. It satisfies
the turn check without changing the context timestamp. Stop checks for an
update receipt and asks once if it is missing. Reporting failures must not
prevent the turn from finishing.

## Retained context

Omitted groups stay unchanged. A supplied group replaces that whole group.

- `purpose`: `title` and `context`, stating the problem and why it matters.
  Keep the title stable until the task changes. Do not turn it into status.
- `now`: `summary` in one plain sentence stating verified progress and optional
  `next`. Omitting `next` removes the old next step. Put progress here.
- `decisions`: the current list, only when it changes. `[]` clears it.
- `historyEntry`: a short `headline` and optional `detail` for a discovery,
  decision, changed request, or major outcome worth remembering. Omit it for
  routine updates. Keep headlines about 60 characters and use plain words.
  Say what changed and why. Distinguish proposals from decisions.
- `emoji` and up to three distinct `emojiAlternatives`: task-specific single
  glyphs for initial identity. Omit them once identity is assigned.

- Optional `icon`: the worktree's drawing. Send it once you understand the worktree's purpose. Send a replacement when the host asks for a one-time redraw, or when the purpose changes and the old picture no longer fits. Resend `purpose` only when the goal changes. Keep the existing emoji as the fallback; do not repeat it in routine updates.
  - Pick a concrete subject tied to the work, such as a database for fixture data. Give it one odd detail that someone could remember after a glance.
  - Vary the composition. Let the subject and the detail suggest the layout. A clock can have a git branch for a hand. A paper boat can hang from the hook of a crane. Two spools can sit at opposite corners with a thread between them. Try a centered shape, a diagonal, a stack, or an overlap as the subject calls for it. Use the project's recent drawings to choose a different subject and overall silhouette.
  - Send an `iconDescription` with every `icon`. Name the subject, its odd detail, and how they fit together in a few words, such as `a clock with a branching hand`. Graftty shares these descriptions with other agents in the project.
  - Use one wide `<svg viewBox='0 0 96 64'>` of at most 16 KB, built only from `path`, `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `g`, `text`, and linear or radial gradients. Single-quote attributes so the drawing fits in the JSON string.
  - Paint only with the tokens `primary`, `primary-light`, `primary-dark`, `accent`, `accent-light`, `ink`, and `white`, or with `url(#id)` for a gradient built from them. Graftty assigns each worktree's colors and adds a white outline.
  - Outline shapes in `ink` with a stroke width near 2.5. Graftty shows the drawing about 60 points wide. Give the outline and the odd detail enough room to read at that size and in any palette.
  - Use the resolved Ghostty theme colors supplied in the turn context as a contrast reference for the drawing. Paint with SVG palette tokens.
  - When the project suggests a world, such as sailing, you may add one supporting element from it, like a life ring standing in for a check mark. Never make it the subject.

  For branch date parsing, a clock with a branching hand.

  ```svg
  <svg viewBox='0 0 96 64'><g stroke='ink' stroke-width='2.5' stroke-linecap='round'><circle cx='48' cy='32' r='27' fill='primary'/><circle cx='48' cy='32' r='21' fill='primary-light'/><path d='M48 43V19m0 16c0-6 11-4 11-11' fill='none'/><circle cx='48' cy='43' r='3' fill='accent'/><circle cx='48' cy='19' r='3' fill='accent'/><circle cx='59' cy='24' r='3' fill='accent'/></g></svg>
  ```

  For reconnecting a sync link, two spools joined by a loose diagonal thread.

  ```svg
  <svg viewBox='0 0 96 64'><g stroke='ink' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><path d='M25 21c21-14 20 27 42 22' fill='none' stroke-width='4'/><path d='M12 7h24v6h-4v13h4v6H12v-6h4V13h-4Z' fill='primary'/><path d='M16 15h16m-16 5h16m-16 5h16' fill='none'/><path d='M62 33h24v6h-4v13h4v6H62v-6h4V39h-4Z' fill='accent'/><path d='M66 41h16m-16 5h16m-16 5h16' fill='none'/></g></svg>
  ```

## Explicit attention

An ask requires an answer. Send it only when input is needed. Include enough
background for someone who has forgotten the worktree to answer. When there
are clear choices, give 2 to 4 options with a short label, a few words of cost
when useful, and `suggested: true` on your pick. Labels must not start with
`!` or `/`.

```json
{"attention":{"kind":"ask","question":"Ship now or wait for CI?","background":"The regression test passed; the suite is running.","options":[{"label":"Wait","cost":"About 15 minutes","suggested":true},{"label":"Ship now","cost":"Full-suite result unknown"}]}}
```

An ask becomes actionable when its turn stops. It expires when that agent
resumes or the user dismisses it. Ask again if the question still matters.
An older ask is never copied into a later turn.

A notice needs review or acknowledgement, with no answer controls:

```json
{"attention":{"kind":"notice","message":"The fix is ready to review."}}
```

Reserve notices for reviewable outcomes, important failures, and handoffs.
They stay unread until acknowledged, even if you continue working. Routine
progress and test results belong in `now`. A finished turn alone does not
request attention. Provider-owned prompts stay in the terminal.

Context updates, reads, and legacy reports use a private file handoff and need
no control-socket permission. Both Context and Needs attention use retained
host context on Mac and mobile.
Do not mention the report in your response unless the command fails; then
mention the failure in your final response.
Do not send an extra final response for the update or acknowledge routine
team notifications that need no action.

If `graftty` is absent from PATH, use
`/Applications/Graftty.app/Contents/Helpers/graftty`.

Load these skills when relevant:

- [graftty-team](../graftty-team/SKILL.md) before messaging, delegation, durable
  roles, or app-control commands.
- [graftty-preview](../graftty-preview/SKILL.md) for useful visual explanations,
  requested file previews, and finished review artifacts. Run `graftty preview`.
- [graftty-open](../graftty-open/SKILL.md) for requested URLs or explicit
  requests to open files in their default app.
