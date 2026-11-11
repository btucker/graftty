---
name: graftty
description: Report a brief Graftty Attention recap before ending a tracked agent turn.
---

# Graftty

Keep the problem being solved and why it matters front and center. The recap
helps the user recover their context when returning to this worktree. Lead with
that purpose, then explain progress, decisions, and what happens next.

The current brief and the history serve different purposes. Current-state fields
replace the previous brief, so retaining unchanged context and decisions is useful.
History entries tell the story of what changed and why. Most reports need no
history entry; do not invent a milestone just because a turn ended.

Send your first report as soon as you understand the task and why it matters,
before starting long work such as builds, test runs, or broad edits. A rough
early brief is more useful than a polished late one: the user can see what you
are working on while you work. Refine it in later reports.

During each top-level turn in a tracked worktree, run this before your final response:

```sh
graftty attention report --stdin <<'GRAFTTY_ATTENTION_7F3A91C2'
{"title":"Posting detail model evals","context":"Model costs limit how many postings we can process accurately.","completed":"v3 scored 0.910 against a700's 0.935.","next":"Evaluate v3 on the new holdout.","decisions":["Compare models on the same holdout before changing the production model."],"historyEntry":{"headline":"v3 nearly matched a700 on the baseline.","detail":"Its 0.910 score versus 0.935 makes it worth checking on the new holdout before choosing the cheaper model."},"emoji":"🧪","emojiAlternatives":["🔬","📊"]}
GRAFTTY_ATTENTION_7F3A91C2
```

Keep each field brief:

- `title`: recognizable worktree purpose. Keep it stable across stops, milestones, and implementation steps.
- `context`: include one sentence stating the problem and why solving it matters, ideally under 120 characters. Preserve that motivation as work progresses; refine it when understanding improves. Put status updates in `completed`.
- `completed`: verified recent progress toward that purpose; state unknown results honestly.
- `next`: remaining concrete work.
- `emoji`: task-specific subject. Include up to three distinct task-related `emojiAlternatives`. The first report assigns the worktree's enduring emoji.
- Optional `icon`: the worktree's drawing. Send it once you understand the worktree's purpose. Send a replacement when the host asks for a one-time redraw, or when the purpose changes and the old picture no longer fits. Set `purposeChanged: true` only for an actual purpose change. Keep sending `emoji` as the fallback.
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
- Optional `need`: a brief question or action only when the user must decide or supply something before work can continue. Omit it when no input is needed; still report completed turns.
- Optional `catchUp`: include it with every `need`, in at most 600 characters, written for someone who has forgotten this worktree: what you are doing and why, what you found, the choices and what each costs, and what you recommend. Graftty shows it beside the question, so the user can answer without asking you to explain again. For example: `"need":"Merge now or wait for CI?","catchUp":"The fix is a 6-line reorder; CI takes 25 min and last failed on an unrelated flake. I'd merge now."`
- When you ask the user a question with choices, such as with AskUserQuestion, always include an "Explain more" choice. If they pick it, catch them up as `catchUp` would, then ask again.
- Optional `decisions`: the complete current list of decisions worth retaining, up to eight short strings of at most 200 characters each. Omission preserves the prior list; `[]` clears it. Include the reason when it helps explain a choice.
- Optional `historyEntry`: an object with a `headline` of at most 160 characters and optional `detail` of at most 300 characters. Record a discovery, decision, changed request, or major outcome that helps the user remember how the work got here. The headline must say what changed; use detail only to explain why or supply evidence. Omit it for routine updates, repeated conclusions, and ordinary test runs. Do not copy the current brief or accumulated decisions. Distinguish proposals from accepted decisions and attempted work from verified results. A new entry adds to history; reusing a headline does not edit an earlier entry.
- Legacy `checkpoint` is accepted for older agents. Use `historyEntry` for new reports; do not send both.
- Optional `purposeChanged`: set to `true` only when the problem or goal actually changes. Then provide the new title and problem context, and the decisions that still apply. Finishing a step or changing implementation approach does not by itself change the worktree's purpose.

Report during the ordinary turn. The command publishes the brief immediately.
Stop verifies the report and asks for a correction only if it is missing. If reporting fails, mention the failure in your ordinary
response. Do not send an extra final response for a recap. Routine team membership
and merge notifications that require no action need no visible acknowledgment.

The report uses a private file handoff, so it needs no control-socket permission. Do not mention the report in your response unless the command fails; then mention the failure in your final response.

If `graftty` is absent from PATH, use `/Applications/Graftty.app/Contents/Helpers/graftty` or the matching installed app's helper.

Load these skills when relevant:

- [graftty-team](../graftty-team/SKILL.md) before messaging, delegation, durable roles, or app-control commands. It explains permission selection before the first socket call. Pinned roles outlive PR closure; pinning does not establish agent availability.
- [graftty-preview](../graftty-preview/SKILL.md) whenever a visual would explain something better. Create self-contained HTML and run `graftty preview` before responding. Also use it for requested file previews and finished review artifacts; tool output and Markdown alone do not open the native preview.
- [graftty-open](../graftty-open/SKILL.md) for requested URLs or explicit requests to open files in their default app. Source edits and internal inspection files need no preview.
