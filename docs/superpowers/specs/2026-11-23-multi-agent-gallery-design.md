# Multi-agent worktree: stage and gallery

Date: 2026-11-23
Status: draft for approval
Sketches: `docs/design-spikes/multi-agent-worktree/` (`gallery-rails.html` for Mac and iPad, `phone.html` for iPhone, `sidebar-stack.html` for the sidebar; `directions.html`, `gallery-plus-lanes.html` and `strip-cards.html` record the options that were considered)

## Intent

When several agents share one worktree, the user mostly talks to one of them. That agent starts others for design review, code review or parallel development, and it reports their results back. Today each agent is an equal tab. A tab shows a status badge and a terminal title, so the user has to remember what each tab is doing, and usually does not care, because the agent they are talking to is their interface to the rest.

This design replaces the tab strip with a **stage** and a **gallery**. The stage is the terminal the user is working in. The gallery shows every agent in the worktree as a small live terminal with its own scroll history, so the user can see what the others are doing at a glance and drop into any of them.

## Goals

- The user can tell what each agent in a worktree is doing without opening it.
- The user can see each agent's message history, and jump to a point in it, without opening it.
- Any agent stays one action away from a full, interactive terminal.
- Layout stays as flexible as today: two or more agents can be shown side by side.
- Mac, iPad and iPhone follow one model, adapted to screen size.

## Non-goals

- No new status reporting from helper agents. Tiles use only data the app already has.
- No kanban board, activity ticker, or multi-lane scroll rail. These were considered and dropped (see Approaches).
- No change to the primary-agent rules: which agent owns the worktree's retained context and who may edit files (CONTEXT-76, CONTEXT-86) are untouched.
- No explicit "lead" setting. The design has no lead concept in the UI at all; the stage is simply whichever agent the user selected.
- The web client is out of scope. (My call, not discussed.)

## Anti-goals

- **Showing an agent in a tile must never resize its terminal or take display ownership.** A tile is a scaled presentation of the terminal at its current grid size, in the same spirit as follower presentation scale (OWN-2.9). A design that works visually but sends resizes when the gallery opens, zooms, or swaps would be a failure; see the resize-cascade history behind IOS-4.39 to 4.41 and TERM-11.20.
- The gallery must not make the terminal narrower in the common single-agent case.
- Tiles must not shout. Status uses the pinned-tile dot (LAYOUT-2.225) and dimming for finished agents, and nothing else: no saturated per-agent colours, no borders, no spinners.

## The model

One rule holds at every size: **a terminal, then its scroll rail on its right edge, with time running downward.** The stage follows it today. A gallery tile is the same thing in miniature.

### Tile

A tile shows one agent:

- **Thumbnail:** a live, scaled-down view of the agent's terminal.
- **Caption, line one:** the live terminal title, falling back to the assignment name, as tabs do today (LAYOUT-2.188).
- **Caption, line two:** the agent's question when it is waiting on the user; its result when it has finished; otherwise its status label.
- **Tile rail:** the agent's scrollback map (CONTEXT-30, CONTEXT-36) on the tile's right edge, upright, with the same three mark kinds and the viewport outline.
- **Status dot:** the dot pinned agent tiles already use (LAYOUT-2.225), before the name: an orange dot only while the agent asks for user input, a pulsing blue dot while it works, faded while its host sleeps, and no dot otherwise. This replaces the tab's status badge; the tile has no accent border.
- **Finished state:** dimmed, as finished tabs are today, and kept until dismissed.

The last tile in every gallery is an **empty tile** for starting a new agent in the worktree. It replaces the existing new-agent controls on the tab strip and in the phone's agent menu.

Shells are not agents and stay in the terminal drawer (LAYOUT-2.240).

### Tile rail interaction

The tile rail behaves like the stage rail (CONTEXT-57.x):

- Hover, touch or scrub magnifies nearby marks and shows the grouped preview cards, stacked vertically to the rail's left, sized by distance from the focused message, with ages.
- The cards are not confined to the tile. They may cover the tile, neighbouring tiles and the stage as far as they need. Near a screen edge they shift to stay on screen.
- Activating a mark or its card puts that agent on stage, scrolled to that message (CONTEXT-57.7).

## Mac and iPad

- The agent tab strip is removed. The gallery is a single column on the right of the worktree's content, with tiles stacked vertically in the order agents were started. Tiles can be dragged to reorder, replacing tab reordering (LAYOUT-2.186). Tile order needs its own ordered agent list in the layout, because off-stage agents are no longer on the canvas; like the layout today it is per device and does not sync.
- The stage keeps its own full-size rail, unchanged, between the terminal and the gallery.
- **Every agent always has its own tile,** whether it fills the stage, sits in a split, or is off stage. Tiles for agents on stage are marked as such, and tiles never reshuffle when the user switches.
- **Click a tile body:** that agent replaces the agent in the focused stage pane, which goes back to being a tile only. If the clicked agent is already on stage in another pane, that pane takes focus instead; a terminal is never shown twice on the stage. (My call.)
- **Removing a stage pane:** each pane of a split stage has a control that takes its agent off the stage without closing the agent. The stage is never empty; the last pane cannot be removed. (My call.)
- **Drag a tile onto the stage:** splits, placing the agent beside what is there. This reuses today's drag-a-tab-to-a-pane-edge behaviour (LAYOUT-2.197). Each stage pane has its own rail, as today (CONTEXT-57.6).
- There is one gallery per worktree. It lists every agent once, whether or not it is currently on stage. Tab groups as a container for several tabs go away: a stage pane shows exactly one terminal.
- **Shells on the stage:** a shell can still be moved from the terminal drawer onto the stage beside an agent, as today. It has no tile and stays listed in the drawer. Agents started by hand inside a shell are treated as shells, as today. (My call, proposed to the user and not yet confirmed.)
- **Questions from off-stage agents:** when an agent that is not on stage asks the user something, the question, its options and the answer field appear at the top of the focused stage pane, named for the asking agent, so the user can answer without switching. This replaces the banner under the asking agent's tab row (LAYOUT-2.196). The tile also shows its orange dot and the question in its caption.
- **Single agent:** the gallery starts collapsed, so the terminal keeps its full width. The control that opens it carries a "+" for adding an agent. When a second agent starts, the gallery opens by itself.
- **Hiding:** the user can collapse the gallery at any time. While collapsed, the control shows how many agents need the user.
- A finished agent selected onto the stage shows the existing completed-agent content (result, transcript, Resume).
- **New agents:** an agent added from the command line appears as a tile and does not change the stage; one started from the empty tile goes on stage. This is today's rule (AGENT-6.128).
- The remote-Mac workspace view uses the same layout. (My call, not discussed.)

## Worktree sidebar

- The per-agent rows under a worktree are removed. The sidebar lists worktrees; the gallery lists a worktree's agents. LAYOUT-2.178 is retired.
- A worktree with two or more agents shows an **agent logo stack** centred under its 60 by 40 point identity slot (LAYOUT-2.230): one provider logo per agent, overlapping, in gallery order, in a single muted tone. A single-agent worktree shows no stack and its row is unchanged. Past what fits in the slot, the stack ends in a count.
- Status on a logo is a **halo** around it, not a dot, because a dot is too small to read on an 18-point logo: an orange halo while the agent asks for user input, a pulsing blue halo while it works, none otherwise, following the same conditions as the tile dot (LAYOUT-2.225). A finished agent's logo is dimmed. A logo with a halo is drawn above its neighbours in the stack, the asking one on top.
- **Hovering the stack expands it** so the logos no longer overlap; the expanded stack may spill over the row's text.
- **Resting the pointer on a logo** shows the title of that agent's terminal.
- **Clicking a logo** selects that agent: the worktree opens with it on stage.
- The row's name and single status line (LAYOUT-2.222) are unchanged.
- Selecting a worktree row puts the agent that most needs the user on stage, if one does, as the phone does today (IOS-13.16); otherwise the stage is as it was left. (My call.)
- The stack appears in the mobile worktree list as well. With no hover there, tapping the stack expands it and tapping a logo selects that agent. (My call.)
- Pinned tiles are unchanged.

## Right-hand column

Context also opens on the right today and reserves its own width (CONTEXT-55). To avoid two columns squeezing the terminal, the gallery and Context share one column: the gallery at the top, Context opening beneath it. Context's "Completed agents" list is removed, because finished agents stay in the gallery with their result in the caption.

## iPhone

The phone shows either the stage or the gallery, never both.

### Stage

Today's terminal screen, unchanged apart from one addition: when another agent in the worktree is waiting on the user, a small chip under the top row names it; tapping the chip puts that agent on stage. With nobody waiting, nothing is added.

- Typing happens only on the stage.
- Pinch on the stage terminal keeps its current meaning, text size (IOS-6.8, IOS-6.21).
- The scrollback map card stays as it is (CONTEXT-37).
- Opening a worktree still lands on the stage of the agent that most needs the user (IOS-13.16), not on the gallery.

### Gallery

Tapping the agent's name on the stage opens the gallery. It replaces today's agent menu.

- Tiles fill the screen in one of two sizes: **4-up** (two by two) and **2-up** (two stacked). There is no 1-up gallery; the stage is a separate view.
- **Pinch** moves between 4-up and 2-up and goes no further. The gallery remembers the size it was left at.
- **Tap a tile** to put it on stage.
- With more agents than slots, the gallery scrolls. The empty new-agent tile is always last: with three agents it fills the fourth slot at 4-up.
- Tiles are watch-only. A vertical drag on a tile's body scrolls the gallery, not that terminal; an agent's history is reached by scrubbing its rail. (My call: one surface cannot scroll both.)
- Scrubbing a tile's rail magnifies marks and shows the preview cards to its left, free to cover the neighbouring tile; lifting on a card opens that agent on stage at that message.
- The agent menu's other entries today, Terminal and About this worktree, move to the gallery's top row. (My call, not discussed.)

## Constraints found in the code

- **Tiles attach as previews.** A `preview` attachment role already exists and cannot take display leadership (OWN-1.5). A visible interactive attachment would take leadership of a leaderless helper (OWN-1.7), so tiles must use the preview role. This is how the anti-goal on resizing is met.
- **Helpers keep the grid they were launched with** until they are first put on stage. Their thumbnails may therefore wrap differently from the stage. (My call, following from the anti-goal.)
- **Caption data exists:** the result (`ManagedAgent.completion.result`, `AgentSessionInfo.result`) and the status label (`AgentAssignmentStatus.label`). The worktree context exposes one question per worktree; when a second agent is also asking, its question text has to be read from the pending requests.
- **Tile rails need a mounted terminal per agent,** because marks are located in terminal rows (CONTEXT-30). The phone's retained pane pool defaults to four, which bounds how many tiles can show live rails at once; how to handle more is left to the builder.

## Approaches

Four directions were sketched in `directions.html`:

1. **Swim-lane rail.** The stage's scroll rail gains a lane per agent on a shared time axis. Good at history, weak at "what is it doing now", and it needed a shared axis the rail does not have today (the rail is laid out by scrollback row, not by clock).
2. **Board strip.** A kanban of assignments folding to one line of counts. Good at "what needs me", but mostly empty with two or three helpers, and it needs a live status line from every helper, which does not exist.
3. **Stage and gallery.** The agent in use has the stage; the rest are live thumbnails. Good at "now", layout stays free; no history by itself.
4. **Chatter line.** One quiet status line under the stage. Cheapest on screen, but needs the same new status line as the board and shows no history.

**Picked: 3, with 1 folded into it.** The user chose the gallery and wanted the history of the swim lanes as well. Rather than a multi-lane rail, each tile carries its own agent's rail. That gives per-agent history with no shared time axis and no new data, and the multi-lane rail was then dropped as redundant.

Two sub-decisions on the tile rail (`gallery-plus-lanes.html`, `strip-cards.html`):

- Gallery position: stacked on the right, over a strip along the top where tabs are today, and over lanes that flow down into tiles.
- Rail orientation: a horizontal strip under each tile was tried first. Its preview cards stacked vertically while the strip ran horizontally, which read badly. Turning the rail upright on the tile's right edge fixed that and made tile and stage follow one rule.

## What changes in the existing requirements

Indicative, for the builder to confirm against `SPECS.md`:

- **Removed or replaced:** the tab strip and its sizing (LAYOUT-2.245), tab-group menus (split into pane, move to tab group, merge group), the phone's agent switcher menu (`CompactAgentBar`).
- **Reused:** the pinned-tile status dot (LAYOUT-2.225) and, on Mac, its hover summary (LAYOUT-2.228).
- **Carried over to tiles:** title fallback (LAYOUT-2.188), finished dimming and retention, reorder by drag (LAYOUT-2.186), drag to split (LAYOUT-2.197).
- **Extended:** the scrollback map requirements (CONTEXT-30, 36, 57.x) apply to tile rails as well as stage rails.
- **Retired:** LAYOUT-2.178 (per-agent sidebar rows), replaced by the agent logo stack.
- **Changed:** CONTEXT-55 (Context shares the gallery's column) and LAYOUT-2.196 (an off-stage agent's question shows on the stage).
- **Unchanged:** primary agent and retained context, the terminal drawer, IOS-13.16 and IOS-13.17, text-size pinch.

## Left to the builder

- How a live thumbnail is produced (a scaled live surface, a periodically refreshed snapshot, or something else), provided the anti-goal on resizing holds and the cost of several live thumbnails is acceptable.
- Tile dimensions, gallery width, and whether tiles grow taller when there are few agents.
- The swap animation. The intent is that a tile and its rail grow into the stage and its rail, a change of size rather than of kind, but a plain cut is acceptable for a first version.
- Where preview cards flip or shift near screen edges.
- Keyboard shortcuts: existing next and previous tab shortcuts should move between agents on the stage.
- Build order. A sensible split is the Mac and iPad gallery first, tile rails second, the phone gallery third.
- The exact control for collapsing and opening the gallery.
