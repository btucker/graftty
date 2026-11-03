# One project across hosts

Status: Draft, 2026-11-03. Awaiting approval. Mockups: [options.html](../../design-spikes/multi-host-projects/options.html). The Mac mocks follow a real screenshot; iPhone and iPad follow the code and are rougher.

## Why

Graftty keeps each host's projects separate. A repository checked out on a Mac and a Linux box appears as two projects on Mac, and on mobile you must pick a host before you can see anything. Which host a worktree lives on isn't useful while scanning for work. It matters once you're in the worktree, and when you decide where new work goes.

## Goals

- Checkouts with the same git origin appear as one project on Mac, iPhone and iPad.
- The sidebar stops surfacing hosts, except where rows would otherwise be ambiguous and on Pinned Agents.
- An open worktree always says which host it's on.
- Mobile loses its host selector. Projects from every host appear together.
- Add Worktree asks which host when the project has more than one.
- Sidebar rows become simpler: a name plus one status line.
- Pinned Agents keep a manual order that's the same on every device and can mix hosts.
- Projects keep a manual order that's the same on every device.
- Background connections never wake a host. Only something that needs that host does.

## Non-goals

- Offering hosts that don't have the project, or cloning on the fly when creating a worktree.
- Automatic host placement. `HostPlacementPlanner` ranks by capacity only and doesn't check project presence. An "Automatic" Host menu item can come later.
- Host-to-host connections. Nothing here requires hosts to reach each other.
- The web client. It's served by one host, so it has nothing to merge.

## Anti-goals

- Repeated per-row host decoration on temporary worktrees.
- A selector that hides another host's work behind a mode, including a per-project filter.

## Decisions made by the user

1. **One mixed list.** Worktrees from all hosts share a list, with no host sections or filter.
2. **Host appears on the open worktree.**
3. **No active agent means "Where we are".** A worktree with no active agent shows that text in the sidebar.
4. **Pane rows leave the sidebar.** The tabs already show them. The user reports that dragging panes in the sidebar doesn't work; this wasn't independently tested.
5. **Manual order goes away for temporary worktrees,** on single-host projects too. Manual order remains in Pinned Agents.
6. **Host labels.** Pinned Agents always show the host when the project is on more than one host. Temporary rows show it only when names clash.
7. **Pinned order is the same across devices,** using per-row ranks merged by each device. The user confirmed this model, including that a device only sees pins from hosts it can reach.
8. **Port chips move to the Mac header** for the selected worktree.
9. **Add Worktree offers hosts that have the project.** The user described choosing a host "if there are multiple options for that project". The Host row form below is a builder-facing proposal.
10. **Folders apply only to Pinned Agents.** Temporary worktrees are a flat list.
11. **A host wakes only for an interaction that needs it,** such as opening one of its worktrees.
12. **Project order syncs,** in a similar way to pinned order.

## Project identity

- Two checkouts are the same project when their normalized `origin` is equal, using the existing `GitRepositoryOrigin` (`Sources/GrafttyKit/Git/GitRepositoryOrigin.swift`). It already treats GitHub and GitLab SSH and HTTPS forms as equal.
- Each host computes its own key and publishes it as a new optional field on `SidebarProject` and `RemoteRepositoryInfo`. Neither carries git origin today. Clients do the merging, so hosts don't change their project model.
- These stay separate projects, as they are today: no origin, older hosts that don't send the key, and forks. Only `origin` is compared, not `upstream`.
- Two checkouts of one origin on the same host merge too. The Host menu shows the path, such as `build-box · ~/src/graftty`.
- The merged project's name is the repo name from the origin. Different origins with the same name stay separate and show the owner, such as `acme/app` and `me/app`.

## Sidebar

### Rows

Each worktree row is its emoji, its name, any PR/MR badge (`LAYOUT-2.81`) and any ahead/behind counts, plus at most one status line. The line is the first of these that applies:

1. **An agent needs you:** the question, in the existing attention style. Clicking it opens the pane that asked, as it does today.
2. **`graftty notify` text** (`STATE-2.3`): the text, in the attention style. Clicking selects the worktree, or opens the pane if the notification names one.
3. **An agent is working:** its live title. With several working, "2 agents working".
4. **No active agent:** `brief.completed`, the context panel's "Where we are" text, dim and clamped to two lines. Paired devices already receive it.
5. **Nothing to say:** just the name.

"Active" means working or needing input. An agent sitting idle at its prompt doesn't count as active. `MobileWorktreeOverview.State` already distinguishes these states.

The attention hand moves from the pane row to the worktree name. An unread agent stop with no question keeps the hand and today's rail badge and navigation, and its "Where we are" text isn't dimmed until viewed, so "just finished" doesn't look like "finished days ago". Rail badges cover all of a project's hosts. Acknowledgement still routes to the owning host.

### What pane rows do today and where it goes

| Today, on a pane row | After |
|---|---|
| Live agent title, busy state | Status line |
| Question, attention | Status line and hand on the worktree name; the attention queue still lists every request |
| Jump to a pane (`LAYOUT-2.10`, `IPAD-1.4`) | Open the worktree, then pick a tab. Questions and the attention queue still jump directly |
| Move to worktree menu | Already in the terminal context menu (`TERM-8.10`) |
| Drag a pane to a worktree (`PWD-1.4`, `PWD-1.5`) | Removed |
| Port chips (`PORTS-3.x`) | Mac header |
| Copy web URL | Terminal context menu; the sidebar pane menu is its only entry point today |

This applies with the project column on or off. With it off, rows are grouped under project names and the Remote Hosts section goes away.

### Host labels

Host names sit directly after the worktree name, clear of the ahead/behind counts.

- Pinned Agents: always, when the project is on more than one host.
- Temporary rows: only when another row in the project has the same name.
- Single-host projects: never.
- The project rail shows no host names. A project is marked Offline only when none of its hosts are reachable.
- A sleeping host's rows stay visible. See [Sleeping hosts](#sleeping-hosts). Temporary rows say "asleep" without the host name, and pinned rows say "mini-m1 · asleep".
- Any other unreachable host's rows are hidden, in line with `REMOTE-13.9`, and one dim line stays at the end of the list, such as "mini-m1 is offline".

### Temporary worktree order

Always recent activity, across all hosts. The Recent Activity control goes away, leaving Add worktree on that line. Today each host ranks its own list and sends only the result, so hosts need to publish an activity time for clients to merge on. Small clock differences between hosts are acceptable. Saved manual orders are ignored for temporary worktrees. `setWorktreeOrder` and `WorktreeOrderMode` can go, but older hosts must keep working.

### Pinned Agents order

- Each pinned worktree stores a rank on the host that owns it, published with its sidebar metadata. Each device sorts all the pinned rows it can see by rank.
- The rank is a fractional index: a sortable string that always leaves room for a row between two others.
- Dragging a row computes a rank between its new neighbors and writes it to that row's host only, through a new management request. Other devices pick it up from that host's normal updates.
- Ties break on host and path, so every device agrees. If two devices drag the same row, the last write to that host wins.
- A device that can't reach a host, and has no sleeping rows for it, shows the remaining pins in the right relative order. The missing rows return to the same place.
- Default checkouts stay first (`LAYOUT-2.103`), sorted by host name so devices agree, and aren't draggable.
- Ranks are first assigned from each host's current order, so existing pins interleave until dragged.
- Pins on an older host have no rank. They sit last in their host's order and can't be dragged across hosts. `LAYOUT-2.61` no longer applies to pins, except for those hosts.

### Folders

Folders appear only in Pinned Agents, on single-host projects too.

- **Temporary worktrees are flat.** A worktree in `.worktrees/feature/foo` shows its full relative name, `feature/foo`. Name clashes compare that full name.
- **Pinned folders merge across hosts.** Pins with the same parent in their relative name share one folder, so `agents/reviewer` on one host and `agents/nightly` on another form `agents`. The existing two-member minimum (`LAYOUT-2.32`) counts across hosts.
- **Inferred folders stay per host.** Folders inferred from paths outside `.worktrees` (`LAYOUT-2.33`) describe one machine's disk, so they don't merge. Same-named ones stay separate, as in `REMOTE-14.6`, and show the host.
- **Order inside a folder uses the same ranks.** A folder sits where its highest-ranked member would, and members sort by rank inside it. Drags stay among siblings (`LAYOUT-2.34`). The new rank goes to the dragged row's host.
- Collapse state stays local to the device.

### Project order

Projects use ranks too, on the rail and the mobile Projects list. A merged project can live on several hosts, so unlike a pin it has no single owner.

- Each host stores a rank and a changed-at time for each of its projects and publishes them on `SidebarProject`.
- A merged project uses the rank with the newest time. Ranks without a time lose to any with one. Between two without a time, the lowest wins. Ties break on project id.
- Dragging computes a rank between the new neighbors and sends the same rank and time to every reachable host with that project. Sleeping hosts aren't woken for this. If none is reachable, the drag wakes the last-used host, as it needs one to write to. If that fails, the project returns to its old place.
- A device that sees a reachable host holding an older value copies the newest value to it, so a host that missed a drag catches up.
- Ranks start without a time, from each host's current order. This Mac's existing `SidebarProjectOrder` seeds the ranks of its own projects. Projects interleave until dragged.
- A newly added project goes last on its host (`LAYOUT-2.38`). If it joins a project that was already dragged, its rank has no time and loses.
- Each device caches ranks, so an unreachable project keeps its place.
- Projects on older hosts have no rank. They sit last in that host's order, and moving them uses `moveProject` as today.

Clock differences matter here only when two devices drag the same project within moments of each other. Either result is acceptable.

## Open worktree

Remote worktrees always show their host. "This Mac" appears only when the project also lives on another host, so people with one machine never see it.

- **Mac header:** `graftty / 🧪 linux-tests · build-box ⌄`, with the host inside the breadcrumb before the chevron. The context panel heading matches.
- **Mac port chips:** after the PR button, covering every pane in the worktree. Clicking opens as today, and extras collapse into a menu. `PORTS-3.4`, which hides chips during a pane capsule, no longer applies.
- **iPad:** the host leads the existing toolbar subtitle, ahead of the PR number and purpose.
- **iPhone worktree screen:** the host joins the project caption above the worktree name. The full-screen terminal hides its navigation bar, so there the host appears only in the context drawer's heading.
- iPhone and iPad keep their existing port rows.

## Add Worktree

- Project first, then host. This reverses the mobile order in `REMOTE-13.10`.
- A Host row is the first field, because each host has its own branch list. It's hidden when the project has one host.
- It lists only hosts that have the project. Sleeping hosts are selectable, and choosing one wakes it to load its branches. Other offline hosts are listed but disabled.
- It defaults to the last host used for that project, unless that host is asleep and another is awake. Then it defaults to the awake one, so opening the sheet doesn't wake anything. If every host is asleep, opening the sheet wakes the last-used one.
- Changing host reloads the branch list. A typed name carries over, and a selected branch that doesn't exist on the new host is cleared.

## Mobile navigation

- **iPhone:** Projects → Worktree → Terminal. `HostPickerView` stops being the root.
- **iPad:** the host menu goes away.
- **Hosts screen:** behind a gear, on both. It pairs and forgets hosts and shows their status. It doesn't change what the app shows.
- **Connections:** on foreground, connect to every paired host, showing cached rows immediately. `RemoteConnectionCoordinator` is already keyed per host, but `IPadAppState` holds one `selectedHostId` and one `latestWorktrees`, and `RootView` stops retained panes when the host changes. Selection must become host plus path. The battery and startup cost is unmeasured, so measure it first and bring the result to the user before building the rest of mobile. Build the feed to support hosts that are known but not connected from the start, because offline hosts need that anyway.
- **De-duplication:** a Mac reached both directly and through another Mac would list every row twice. De-duplicate by owning device and prefer the direct route.

## Sleeping hosts

Today, every dial sends Wake-on-LAN when the host has verified wake addresses (`REMOTE-2.12`). `RemoteHostDialer` passes them unconditionally. That was fine when a dial followed a tap on a host. It isn't once devices connect to every host, on foreground on mobile and on launch or reconnect on Mac. Dials become explicit about whether they may wake.

- **Background connections never wake.** That covers foreground, launch, reconnect and the attempt to refresh rows.
- **Anything that needs the host wakes it.** That includes opening one of its worktrees, tapping a question or notification for it, creating a worktree on it, dragging its pinned row, its Pull and Remove actions, and Reconnect (`REMOTE-13.24`).
- **Restoring isn't an interaction.** If the worktree selected at last launch is on a sleeping host, it shows "mini-m1 is asleep" with a Wake button. It doesn't wake on its own.
- **Waking shows progress.** The worktree opens to "Waking mini-m1…". If it doesn't respond, the view says so and offers Try Again. A wake only works on the host's local subnet (`REMOTE-2.12`), so this is what you see away from home.

A sleeping worktree has to stay on screen for you to open it, so this narrows `REMOTE-13.9`:

- **Sleeping means** a host that isn't reachable but has verified wake addresses, which clients already keep across launches (`REMOTE-2.14`). Clients can't distinguish a sleeping Mac from one that's off or away, so "asleep" covers those too.
- **Its rows stay,** drawn dim from the last report, in their usual place, including the last "Where we are" text. They show no live agent status, because nothing is known to be running.
- **Its rows aren't relayed.** A device that only reaches that host through another Mac doesn't see them, and gets the offline line and Reconnect instead (`REMOTE-13.9`, `REMOTE-13.24`).
- **Projects** whose hosts are all unreachable show "Asleep" if any is sleeping, and otherwise "Offline". Opening one shows the cached rows without waking anything.

## Project-level actions

Pull default branch and Remove become per-host in the context menu, such as "Remove from build-box…". `GRAFTTY.md` can differ by host and stays per host. The icon comes from this Mac's checkout, or otherwise the first host that has one. Project position comes from [Project order](#project-order).

## Suggested order

1. Publish the origin key, activity time, pinned rank, and project rank and time from hosts. Make dials explicit about waking.
2. Mac: merged projects, new rows, flat temporary list, merged pinned folders, sleeping rows, header, Add Worktree, pinned and project drag.
3. Mobile: multi-host feed and selection, Projects root, Hosts screen, new rows.

## Left to the builder

- Fractional index format and length limits, and any rebalancing.
- Exact styling of the status line and host label, within the mocks.
- Where the rank fields live in `WorktreeEntry`, `SidebarWorktreeMetadata` and the repository model, and how long a sleeping host's rows are cached.
- Spec IDs and EARS text. `SPECS.md` is generated from `@spec` annotations, and retired behavior includes `IPAD-6.x`, `IPAD-1.2`, `PWD-1.4`, `PWD-1.5`, `LAYOUT-2.10`, and `LAYOUT-2.152` through `LAYOUT-2.156` where they cover order modes. Changed behavior includes `REMOTE-2.12`, `REMOTE-13.9`, `REMOTE-13.10`, `LAYOUT-2.38`, `LAYOUT-2.140`, and `LAYOUT-2.32` through `LAYOUT-2.37` for temporary worktrees.

## My calls, not yet confirmed by the user

- An idle agent at its prompt counts as not active.
- Host names leave the project rail.
- "2 agents working" for several working agents.
- PR/MR badges stay on rows. Nobody asked to remove them, and the screenshot shows them.
- `graftty notify` text takes a status line slot, and unread stops keep the hand with undimmed text.
- Default checkouts stay first and aren't draggable.
- The offline-host line at the end of the list.
- Two checkouts on one host merge.
- Copy web URL moves to the terminal context menu.
- Mobile connects to every paired host on foreground.
- A sleeping host's rows stay visible and dim, with "asleep" on them. Your wake rule needs something to tap, and this changes the earlier "rows disappear" behavior.
- A worktree restored at launch on a sleeping host shows a Wake button instead of waking.
- Add Worktree prefers an awake host over a sleeping last-used one.
- Pinned folders with the same relative name merge across hosts. Folders inferred from outside `.worktrees` don't.
- For project order, the newest change wins across a project's hosts, and devices copy it to hosts that missed it.
