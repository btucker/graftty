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
- Optional `icon`: a drawing of this worktree that Graftty shows in place of the emoji, so make it memorable. Send it once you understand the worktree's purpose. Afterwards, send a new `icon` only in a report with `purposeChanged: true`, and only when the old picture no longer makes sense; Graftty ignores other redraws. Keep sending `emoji`; it remains the fallback.
  - Draw the subject the user would picture, never the activity: a database for fixture data, not a checkmark for testing. Add one odd, specific detail that makes it this worktree's own, such as a 5k price tag on stacked postings.
  - Use one `<svg viewBox='0 0 64 64'>` of at most 16 KB, built only from `path`, `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `g`, `text`, and linear or radial gradients. Single-quote attributes so the drawing fits in the JSON string.
  - Paint only with the tokens `primary`, `primary-light`, `primary-dark`, `accent`, `accent-light`, `ink`, and `white`, or with `url(#id)` for a gradient built from them. Graftty assigns each worktree's colors and adds a white outline.
  - Outline shapes in `ink` with a stroke width near 2.5. At sidebar size only the silhouette and color survive, so let the silhouette carry the meaning, and pick shapes that still make sense in any color.
  - When the project suggests a world, such as sailing, you may add one supporting element from it, like a life ring standing in for a check mark. Never make it the subject.

  For a parser cache, a page of parsed lines with a lightning bolt:

  ```svg
  <svg viewBox='0 0 64 64'><defs><linearGradient id='page' x1='0' x2='1'><stop offset='0' stop-color='primary-light'/><stop offset='1' stop-color='primary'/></linearGradient></defs><rect x='12' y='8' width='34' height='44' rx='4' fill='url(#page)' stroke='ink' stroke-width='2.5'/><path d='M19 20h20M19 28h20M19 36h12' stroke='white' stroke-width='3' stroke-linecap='round'/><path d='M44 30l-8 14h7l-4 14 13-18h-7l5-10z' fill='accent' stroke='ink' stroke-width='2.5' stroke-linejoin='round'/></svg>
  ```
- Optional `need`: a brief question or action only when the user must decide or supply something before work can continue. Omit it when no input is needed; still report completed turns.
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
