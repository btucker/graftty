---
name: graftty
description: Use in Graftty agent sessions to report a short Attention recap before stopping.
---

# Graftty

## Recognize pinned agents

Pinned agents hold an ongoing responsibility across tasks, such as releases or
crash investigation. Their worktrees remain after a PR or MR merges or closes.
The default-branch checkout is always pinned. A pin does not mean the agent is
running or available. For delegation, role instructions, pinning, unpinning, or
removal, load the bundled `graftty-team` skill.

## Report the stopped turn

Before ending a top-level turn in a tracked worktree, report what the user will need to recognize it later. Run `graftty attention report --stdin` with one small JSON object. The CLI stages the report in a private file that the Stop hook hands to Graftty; this does not require control-socket permission. A SessionStart hook asks you to load this skill; if that was missed, the Stop hook may request this report once before allowing the turn to end.

If `graftty` is not on `PATH`, use the helper inside the installed Graftty app bundle, for example `/Applications/Graftty.app/Contents/Helpers/graftty`. Sessions started before Graftty registered its wrapper may show the report immediately because their Stop hook may be unavailable.

```sh
graftty attention report --stdin <<'GRAFTTY_ATTENTION_7F3A91C2'
{"title":"Posting detail model evals","context":"High model costs limit how many job postings we can process accurately.","completed":"v3 scored 0.910 against a700's 0.935.","next":"Run four evals on the new holdout, prod200, and us1000.","emoji":"🧪","emojiAlternatives":["🔬","📊"]}
GRAFTTY_ATTENTION_7F3A91C2
```

Use a recognizable task title, not the worktree name or a generic status. Set `"context"` to one sentence (aim for under 120 characters) explaining the problem this work addresses and why solving it matters. Use the user's goal and known impact to frame it. Put implementation steps and progress in `"completed"` and `"next"`. Set `"completed"` to one sentence on recent verified progress and `"next"` to one sentence on the remaining concrete work. Include one task-specific `"emoji"` and up to three distinct, task-related `"emojiAlternatives"`. Graftty assigns the first unused choice as the worktree's enduring emoji on its first report; later reports cannot change it. Favor a concrete subject of the work, such as 🔔 for push notifications or 🧪 for model evals, over generic status symbols. Add `"need":"<brief question or action for the user>"` only when the user must decide or provide something; preserve the real question instead of inventing one. If results or validation are unknown, say so. Keep each field brief. Do not mention the report in your response to the user: it is private bookkeeping for Graftty, not part of the conversation. If the report command fails, mention the failure in your final response; Graftty will still show a generic stopped card.

Other `graftty` commands use Graftty's main control socket. If a sandbox denies one with `EPERM` or `errno 1`, load the `graftty-team` skill for the socket check and narrowly scoped permission request. Do not request socket permission for `graftty attention report`.
