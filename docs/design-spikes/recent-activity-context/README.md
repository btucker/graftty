# Worktree reports in the Recent Activity list

This spike combines worktree navigation and agent reports in one sidebar. The separate Attention destination is removed. Pinned Agents, the project rail, pane rows, PR badges, and the existing sort choices remain.

Open the self-contained [interactive mock](index.html) in a browser. It uses sample data and does not connect to Graftty.

![A worktree report beside the list, over the terminal](hover-preview.png)

## Approved behavior

A stopped agent's full question appears beneath its associated pane, labeled “Needs your input.” There is no duplicate “Needs input” status. Successfully opening the worktree acknowledges the question and hides it from the row. Dismissal, agent resume, or a newer report also retires that occurrence. The latest recap remains available in the report preview.

On Mac, an information button beside the worktree name opens a native popover. Hovering does not open reports. Clicking outside or pressing Escape dismisses the popover. Reports fit their content, scroll when long, and use the highlighted worktree background and Ghostty foreground colors. The Mac popover contains no Pin, Close, Dismiss request, or Open worktree controls; pane and worktree selection stay in the sidebar. Inline questions align beneath the pane titles.

Inside reports, compact identity metadata sits on a subtle contrasting background. The PR badge shares the worktree-name row, and running status shares a row with report age when space permits. Completed work is labeled, and the question sits in an inset callout. Current input requests use the orange accent; viewed questions use a neutral treatment. See the native captures for [pending input](native-report.png), [a running agent's previous report](native-report-running.png), and [a light Ghostty theme](native-report-light.png).

On iPhone and iPad, holding a row for 500 milliseconds opens the report without selecting the terminal. iPad uses an anchored popover; compact layouts use a sheet. Normal taps open the terminal. Scrolling, swipe actions, and Edit-mode reordering retain their gestures. VoiceOver exposes Show report.

Project counts and pending-worktree navigation retain cross-project discovery. Pending navigation follows displayed folder order and wraps. Reports participate in worktree search. While a report is open, positions and pin/folder membership stay fixed while report content updates.

The native implementation keeps the existing one-latest-recap-per-worktree model. Hosts publish the retained recap after acknowledgement; clients preserve a local fallback for older hosts. Shell notifications and other attention sources keep their existing indicators and routing.

## Validation

The initial browser spike passed 29 interaction and geometry checks. Its screenshots show the original proposal; the approved acknowledgement behavior above supersedes the original question-persistence experiment.

Native tests cover request acknowledgement and failure, retained reports, stale snapshots, path reuse, pending traversal, presentation freezing, report widths, explicit button activation, native popover dismissal, anchor removal, content sizing, theme colors, and inline question alignment. The report was rendered and visually inspected at 260- and 380-point widths. The final Mac checks exercise the information button through the production worktree drag overlay and render both light and dark themes; see the [native worktree row](native-worktree-row.png) and [native report capture](native-report.png). The integrated iPhone Simulator suite passed 444 tests, followed by 24 focused navigation tests after review corrections. Real simulator gestures verified hold, tap suppression, scrolling, swipe actions, Edit-mode reorder, and iPad popover placement.

The latest full SwiftPM run reproduced existing RemoteBranchStore polling, TeamPresenceStorage, and WorktreeSleepWake failures. All three passed focused reruns, totaling 32 tests. The six final report layout and native popover tests also passed. Paired-host hardware navigation, pointer hardware, and spoken VoiceOver still need device verification.
