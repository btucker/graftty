# Context panel: glance and answer

Status: draft for approval (2026-11-11). Supersedes the layout chosen in
`2026-10-26-context-panel-refinement-design.md`; its conciseness layer
(row kinds, folds, peer gists) stays.

## Why

The common failure: the user switches into a worktree, an agent is waiting on a
question, and the user does not have the context to understand what is being
asked. The Context panel (Mac inspector, mobile drawer) is supposed to supply
that, but today it reads as a wall of text:

- The pinned brief and the timeline are two scroll areas of equally loud prose,
  both clipped mid-line at the divider.
- The question is the fourth section of the brief, after the decisions list.
  The agent's catch-up text reaches the panel (`questionCatchUp`) but only the
  mobile ask deck shows it.
- Agents write long, insider prose (commit hashes, "every hosted gate"), and
  titles drift into status ("Crash investigation unaffected by cache stall").

This work began as an exploration of a non-terminal agent mode. The user chose
to make the Context panel useful first. Answering a question from the panel is
the first small piece of that larger idea.

## Goals

1. Opening Context on a worktree with a pending question shows, without
   scrolling: what the worktree is, one sentence on where things stand, the
   question, and the choices with what each costs.
2. The user can answer from the panel, on Mac, iPhone, iPad and a remote Mac,
   without opening the terminal.
3. The default view shows roughly a third of today's words. Everything else is
   one tap away, never clipped mid-line.
4. Reports cost agents fewer words than today, never more.

## Non-goals

- A GUI agent mode, native transcript rendering, or a general message composer.
- Answering a prompt the harness itself is showing (Claude's question picker,
  permission prompts). Those stay "open to answer".
- Changing peer-message gists, the sidebar, or the worktree drawing.

## Anti-goals

- Any report change that makes agents write more.
- Tinted cards or saturated status colour. One accent, used only for
  "Waiting for you".
- Two independently scrolling regions, or text cut off mid-line.
- Newest-first ordering. The timeline stays oldest to newest, like the terminal.

## Decided with the user

- One scrolling column, oldest to newest.
- Glance-first: short headlines and a one-sentence state by default, detail on
  tap.
- A question shows as choices the user can tap to answer.
- The agent report instructions are in scope.
- Choices replace the catch-up paragraph; reports with no question gain nothing.
- On Mac, the top of the Context panel aligns below the tab row.
- The panel's header shows the worktree's title, not the static word "Context".

## Design

Reference sketch (throwaway HTML, not a spec for exact metrics):
round 3, "Waiting for you", "details opened" and "nothing asked" states.

### 1. Panel layout (shared `WorktreeContextPanel`, Mac and mobile)

Top to bottom:

1. **Title bar, pinned.** The brief's title (falling back to the worktree
   name) replaces today's static "Context" label and icon; the close button
   stays. Tapping the
   title discloses, in place: the `repo / worktree` line, the purpose
   (`context`), the decisions list, and the existing "Completed agents"
   section. All are hidden by default.
2. **One scroll view, bottom-anchored**, keeping today's follow behaviour
   (`TimelineFollow`, "Jump to latest"). It holds, in order:
   - the timeline, oldest to newest;
   - a hairline;
   - **the present state** as the last item: `completed` as the loudest text on
     the panel, then `next` in a dimmer line labelled "Next".
3. **Bottom block, pinned.**
   - With a question: the ask block (section 2).
   - Without: one quiet italic line, "Agent working · updated N ago" or
     "Updated N ago".

Removed: the capped pinned brief, its resize divider, and the mobile
collapsed-brief header (`collapsesBrief`). The slim title bar makes them
unnecessary.

Timeline rows:

- A history entry shows its headline and time on one row, dim. Tapping it opens
  its detail in place. The newest entry is not special-cased; the present state
  below it carries the emphasis.
- Other row kinds (user input, peer messages, agent turns, folds, day labels)
  keep their current content and behaviour, restyled to the same hierarchy:
  one or two lines by default, dim, full text on tap. *(My call. The sketches
  only showed history entries.)*
- Type hierarchy, loudest to quietest: question, present state, title, option
  labels, timeline headlines, times and labels. *(My call.)*

Empty and partial states keep today's wording ("No context yet").

### 2. The ask block

Shown when `context.question` is set.

- Label "Waiting for you" in the accent colour, then the question.
- **If the report carried options** and the agent stopped its turn
  (`questionIsStoppedTurn`): one row per option with its label, its cost in a
  dim line, and "Suggested" on the agent's pick. Tapping a row sends the answer
  (section 4).
- **"Why this is being asked"** discloses the catch-up text when present.
- **A one-line reply field** sends free text the same way. It is the only
  input when the report carried no options.
- **"Explain more"** keeps its current behaviour.
- **If the harness owns the prompt** (a provider request): the question and an
  "Open to answer" button only. No options, no reply field.

While a send is in flight the block is disabled; on success it shows "Sent"
until the question clears; on failure it shows the host's message and
re-enables.

The mobile ask deck (`AttentionAskCard`) shows the same options and sends the
same way. *(My call, for parity; the project default is Mac and mobile both.)*

### 3. Report schema (`AttentionRecap`)

Add one optional field:

```json
"options": [
  {"label": "Hold", "cost": "Sidebar fix waits a few days", "suggested": true},
  {"label": "Ship", "cost": "macOS 27.0.1 users may still crash"}
]
```

- 2 to 4 options. `label` required, at most 40 characters. `cost` optional, at
  most 80. `suggested` optional, on at most one option.
- Valid only together with `need`; labels distinct. An invalid `options`
  rejects the report with its own message naming the field.
- Older recaps decode without it; older hosts ignore it.
- `catchUp` stays, and becomes the optional background behind "Why this is
  being asked". No second field. *(My call: fewer fields is less agent work.)*
- Existing length limits do not tighten, so agents on an older cached skill are
  not rejected. Brevity comes from the instructions and from the panel showing
  one or two lines until tapped. *(My call.)*

### 4. Answer delivery

Generalise the existing Explain-more path (`AttentionExplainDelivery`,
AGENT-3.40), which already types a prompt into a stopped agent's pane and
submits it.

- New management request carrying worktree, pane, the answer text, and the
  identity of the question being answered, so a question that changed or
  cleared since the panel drew is refused with "This request has changed or
  already cleared." (the same message acknowledgement uses).
- Same refusals as Explain more: pane gone; pane waiting at a harness prompt.
- The text typed is the option's label verbatim, or the reply field's text.
- Routes: local Mac directly; mobile and remote Mac over the existing relayed
  management channel; headless host as Explain more does today.
- A host too old to decode the request yields "Update Graftty on this Mac to
  answer from here."

Known limit, accepted: if the user has a half-typed draft in that pane, the
answer is appended to it, as Explain more does today.

### 5. Report instructions

Edit both skill files (`AgentPlugins/claude/.../graftty/SKILL.md`,
`AgentPlugins/codex/.../graftty/SKILL.md`) and the hook strings in
`TeamHookRenderer` (`recapGuidance`, `skillGuidance`).

- `completed`: one sentence, plain words, where things stand now.
- `historyEntry.headline`: a short plain phrase, about 60 characters; no commit
  hashes, job counts or internal names. Those belong in `detail`.
- `title`: the purpose; never a finding or a status. (Already the rule; add a
  bad/good example.)
- Questions with clear choices: end the turn and report `need` plus `options`,
  each with a few words of cost, and mark the one you suggest. Do not use the
  harness's own picker for these. `catchUp` becomes one or two optional
  sentences of background.
- Questions with no clear choices: `need` alone, plus `catchUp` as today. Do
  not invent options.
- Remove "always include an Explain more choice"; the panel provides it.

Constraint: the per-turn hook text (`recapGuidance`) must end up no longer than
it is today, and the worked example in each skill must be no longer than
today's.

### 6. Mac inspector alignment

Today the Context panel starts directly under the window header, beside the tab
row. It should start below the tab row, so its top edge lines up with the top
of the terminal content. In `MainWindowDetailLayout`, inset the inspector from
the top by `WorktreeHeaderWash.tabRowHeight`; the header wash shows through
above it. *(My reading of "align below the tabs". The tab row itself does not
widen.)*

## Calls made after the builder check

A reviewer read this document as a builder would. These answers are my calls,
made without the user, to keep the scope tight:

1. **No Explain more in the panel.** The reply field covers "explain this
   first". The mobile ask deck keeps its Explain more unchanged.
2. **Nothing but the title bar is pinned.** The details disclosure, timeline,
   present state, ask block and status line are all items in the one
   bottom-anchored scroll, so the ask block is on screen when the panel opens
   and no block can push the timeline to zero height. "Completed agents" loses
   its own inner scroll view and moves into the details disclosure.
3. **The host refuses an answer unless the stopped question it targets is still
   the worktree's unseen stop.** It does not check that the agent process is
   alive; if the agent exited and left a bare shell, the answer is typed there.
   Accepted risk: the stop clears when the agent resumes or the user dismisses
   it.
4. **The mobile ask deck is unchanged in this work.** Mobile gets options and
   replies through the shared Context drawer.
5. **The inspector inset applies only beside workspace content** (local or
   remote tabs), not beside the waking, creation-progress or placeholder views.
6. **An invalid `options` gets its own CLI error message.** Other fields keep
   the generic one.
7. **A harness-owned prompt shows the question and "Answer in the agent's
   terminal"** with no button. The Mac's existing input banner and the mobile
   terminal already lead there.

## Requirements and tests

Follow the repo's `@spec` and RED/GREEN process. New requirements extend
CONTEXT (after CONTEXT-57) and AGENT-3 (after AGENT-3.48); update in place the
existing specs this changes, including the pinned-brief and collapsed-brief
CONTEXT specs, AGENT-3.39, AGENT-3.40 and IOS-13.20. Regenerate `SPECS.md`.

Protocol types live in `GrafttyProtocol` so they are covered on Linux. Mobile
changes need the iOS build, not only `scripts/swiftpm test`.

## Left to the builder

- Exact spacing, font sizes and the accent colour source in the theme.
- Whether the title disclosure and row expansion animate.
- Naming of the new request and types.
- How to split the work into PRs. A natural order: inspector alignment; schema
  and instructions; panel layout; answer delivery and the ask block.
- The web client, if it renders recaps at all: leave unchanged unless it breaks.
