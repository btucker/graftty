---
name: graftty
description: Report a brief Graftty Attention recap before ending a tracked agent turn.
---

# Graftty

Before ending a top-level turn in a tracked worktree, run:

```sh
graftty attention report --stdin <<'GRAFTTY_ATTENTION_7F3A91C2'
{"title":"Posting detail model evals","context":"Model costs limit how many postings we can process accurately.","completed":"v3 scored 0.910 against a700's 0.935.","next":"Evaluate v3 on the new holdout.","emoji":"🧪","emojiAlternatives":["🔬","📊"]}
GRAFTTY_ATTENTION_7F3A91C2
```

Keep each field brief:

- `title`: recognizable task, not a generic status or worktree name.
- `context`: one sentence explaining the problem and why solving it matters, ideally under 120 characters.
- `completed`: verified recent progress; state unknown results honestly.
- `next`: remaining concrete work.
- `emoji`: task-specific subject. Include up to three distinct task-related `emojiAlternatives`. The first report assigns the worktree's enduring emoji.
- Optional `need`: a brief question or action only when the user must decide or supply something.

The report uses a private file handoff, so it needs no control-socket permission. Do not mention the report in your response unless the command fails; then mention the failure in your final response.

If `graftty` is absent from PATH, use `/Applications/Graftty.app/Contents/Helpers/graftty` or the matching installed app's helper.

Load these skills when relevant:

- [graftty-team](../graftty-team/SKILL.md) before messaging, delegation, durable roles, or app-control commands. It explains permission selection before the first socket call. Pinned roles outlive PR closure; pinning does not establish agent availability.
- [graftty-image](../graftty-image/SKILL.md) to show requested or finished review visuals. Run `graftty image`; tool output and Markdown alone do not open the native preview.
- [graftty-open](../graftty-open/SKILL.md) for other finished review artifacts or requested files and URLs. Source edits and internal inspection files need no preview.
