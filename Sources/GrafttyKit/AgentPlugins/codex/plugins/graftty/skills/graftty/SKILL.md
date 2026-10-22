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

Before ending a top-level turn in a tracked worktree, run:

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
- Optional `need`: a brief question or action only when the user must decide or supply something before work can continue. Omit it when no input is needed; still report completed turns.
- Optional `decisions`: the complete current list of decisions worth retaining, up to eight short strings of at most 200 characters each. Omission preserves the prior list; `[]` clears it. Include the reason when it helps explain a choice.
- Optional `historyEntry`: an object with a `headline` of at most 160 characters and optional `detail` of at most 300 characters. Record a discovery, decision, changed request, or major outcome that helps the user remember how the work got here. The headline must say what changed; use detail only to explain why or supply evidence. Omit it for routine updates, repeated conclusions, and ordinary test runs. Do not copy the current brief or accumulated decisions. Distinguish proposals from accepted decisions and attempted work from verified results. A new entry adds to history; reusing a headline does not edit an earlier entry.
- Legacy `checkpoint` is accepted for older agents. Use `historyEntry` for new reports; do not send both.
- Optional `purposeChanged`: set to `true` only when the problem or goal actually changes. Then provide the new title and problem context, and the decisions that still apply. Finishing a step or changing implementation approach does not by itself change the worktree's purpose.

The report uses a private file handoff, so it needs no control-socket permission. Do not mention the report in your response unless the command fails; then mention the failure in your final response.

If `graftty` is absent from PATH, use `/Applications/Graftty.app/Contents/Helpers/graftty` or the matching installed app's helper.

Load these skills when relevant:

- [graftty-team](../graftty-team/SKILL.md) before messaging, delegation, durable roles, or app-control commands. It explains permission selection before the first socket call. Pinned roles outlive PR closure; pinning does not establish agent availability.
- [graftty-preview](../graftty-preview/SKILL.md) whenever a visual would explain something better. Create self-contained HTML and run `graftty preview` before responding. Also use it for requested file previews and finished review artifacts; tool output and Markdown alone do not open the native preview.
- [graftty-open](../graftty-open/SKILL.md) for requested URLs or explicit requests to open files in their default app. Source edits and internal inspection files need no preview.
