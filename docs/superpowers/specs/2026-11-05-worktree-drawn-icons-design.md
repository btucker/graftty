# Drawn worktree icons

Status: draft for approval, 2026-11-05.

## Intent

A worktree's icon should bring its purpose back to mind at a glance, and it should be memorable. Today each linked worktree shows an emoji that an agent picks in its first Attention recap. That emoji is often unrepresentative:

- **Chosen too early.** It locks at the first recap, when the agent knows least. `label-5000-postings` is 🦊 because its first task was a GitLab sign-in. `CARP-4260-reader-hang-bound` is 💓.
- **Activity instead of subject.** Agents often pick what they are doing (✅ 🔎 🔧) rather than what the work is about.
- **Missing.** A worktree without an agent recap has no emoji. On the user's Mac, 38 of 66 linked worktrees had none.

Agents will instead draw a small illustrated SVG for each worktree. Graftty colors it, adds a white edge and shows it everywhere the emoji appears today.

## How we got here

Six throwaway previews of real worktrees, all rendered at the sizes Graftty uses, settled the direction:

1. Simple one-color line icons conveyed meaning but looked alike. The user wanted color.
2. Detailed two-tone icons read well in the header wash but looked like generic UI icons next to emoji.
3. **Illustrated sticker icons**, each showing the work's subject plus one odd, specific detail, held their own against emoji. The user loved these. Examples: a database with its spreadsheet spilling out, stamped as checked; stacked postings wearing a 5k price tag; a book stuck in the neck of an hourglass; a cracked app window with a bandage.
4. Borrowing the project icon's *style* was invisible at 15 points.
5. Making a project concept the *subject* (sailing scenes for my-sailchicago) made every sibling "a boat". The user rejected it.
6. Keeping each worktree's own subject and adding one element from the project's world in a *supporting role* (a life ring as the QA check, an anchor under a balance scale, a sail on a floppy disk) kept siblings distinct and hinted at the project. The user approved it.

## Goals

- Each linked worktree shows an agent-drawn icon that depicts its purpose and is memorable.
- Worktrees in the same project are easy to tell apart, mainly through color and silhouette.
- Icons work with both Claude and Codex agents.
- Icons appear on every surface that shows worktree identity today, on Mac and mobile.

## Non-goals

- Images from the web, because of licensing and poor search matches.
- Images from an image-generation model. That needs a specific provider, and SVG works with any agent.
- Distinct colors across projects. The user cares about distinctness within a project.
- Changing home checkouts. They keep the project icon (LAYOUT-2.124).
- A backfill (user decision). Drawings appear only as agents report. Worktrees no agent reports from again keep their current emoji or fallback icon. This leaves the "Missing" problem above unsolved for those worktrees, and the user accepts that.

## Anti-goals

A result that technically works but fails the user:

- Icons that change often. An icon you can't rely on isn't memorable.
- Siblings that look alike, as in preview 5.
- Generic UI pictograms, as in preview 2. Accurate is not enough; the icon must be memorable.
- Any drawn content that can run script, load a resource or reach the network.

## Decisions

### Made by the user

- **Style:** illustrated sticker icons that show the work's subject plus one odd, specific detail (preview 3).
- **Color:** Graftty assigns each worktree's color, not the agent. Colors must be distinct from the other worktrees in the same project. Distinctness across projects does not matter.
- **Project world:** when a project suggests a world, an agent may add one element from it in a supporting role. That element must never be the subject and must never replace the main shape or its color (preview 6).
- **Redraws:** the agent redraws an icon only when the worktree's purpose changes so much that the old picture no longer makes sense.

### Made by Claude during brainstorming, open to review

- **Color is assigned once and kept.** Graftty assigns it when it first sees a worktree, on every path that creates one: the app UI, `graftty agent add`, and worktrees discovered on disk. It also assigns colors once to existing worktrees. It never recolors automatically, because a stable color is easier to remember.
- **Color uses a perceptual color space.** Graftty spaces hues in OKLCH, not HSL. In preview 3, HSL hues 70°, 120° and 160° all read as green. It picks the hue farthest from every sibling's hue and from the project icon's dominant hue. In preview 3, a blue icon disappeared under the blue project icon in the row above it.
- **Two color slots.** The agent draws with a primary and an accent color slot plus fixed neutral ink and white. Graftty fills the slots. The accent is the primary hue rotated about 40°.
- **Graftty adds the white edge.** A white outline separates icons from dark backgrounds. Without it, preview 3's scale icon nearly disappeared on a dark header. Agents do not draw it.
- **The emoji remains as a fallback.** It shows until a drawing exists and stays in recaps, so older skills and hosts keep working.
- **A manual override always wins, if the user actually chose it.** LAYOUT-2.78 (`migrateLegacyEmojis` in `SidebarHostNavigation.swift`) marked many old automatic emojis as `.manual` even though the user never chose them. Those legacy-migrated emojis do not block drawings. Only a manual choice made after this feature ships blocks a drawing, so the source needs a value that tells the two apart.
- **Notifications keep the emoji text.** Notification subtitles (`AgentStopNotification.swift`, used by `AgentNotificationRouter` on Mac and by `MobileAgentNotifications` on iOS) stay as they are. The emoji is still reported with every recap, so it is always available there. PNG notification attachments are out of scope.
- **Graftty enforces the redraw rule.** Once a worktree has a drawing, Graftty rejects a replacement unless the agent's latest recap set `purposeChanged: true`, the same way `WorktreeBrief` gates title changes. Rejections give an error the agent can act on. This rule gets its own EARS spec and test.

### Settled during implementation

These replace the matching statements above.

- **Submission:** the drawing travels as an optional `icon` field on the Attention recap. The CLI validates it and reports the specific reason when it rejects one. The host adopts it and removes it before the recap is stored or broadcast.
- **Redraws without `purposeChanged`:** they are ignored, not rejected. A recap is a one-way file handoff, so the host cannot send an error back to the agent. The agent guidance states the rule.
- **Color timing:** the hue is assigned when a worktree first receives a drawing, not when it is created. Color only appears on drawings, so the result looks the same, and a worktree without a drawing never takes a hue from a sibling.
- **Project icon hue:** the Mac host and the headless host record each project icon's dominant OKLCH hue in `ProjectHueRegistry`. Drawings made before the icon loads ignore it.
- **Remote Macs:** worktrees on another Mac keep their emoji on the local Mac's header and breadcrumb. Mobile shows drawings from any host.

## Behavior

### Drawing

- The agent draws an icon once it understands the worktree's purpose, not necessarily in its first recap.
- It redraws only on a recap with `purposeChanged: true` in which it judges the old icon no longer fits. Finishing a step or changing approach keeps the icon.
- Agent guidance appears in the graftty skill (`Sources/GrafttyKit/AgentPlugins/{claude,codex}/.../SKILL.md`) and the hook text in `TeamHookRenderer.swift`. It covers:
  - Show the subject the user would picture, never the activity.
  - Add one odd, specific detail.
  - Use a 64-unit view box with about 2.5-unit ink outlines.
  - Use two color slots, ink and white only.
  - At 15 points only the silhouette and color survive, so the silhouette must carry the meaning.
  - Shapes must still make sense in any assigned color. Preview 4's amber database read as coins.
  - Optionally use one supporting element from the project's world, never as the subject.
  - Short worked examples from the previews.
- The agent may inspect the project's icon, name and README for the project-world element. Graftty already finds the icon (`ProjectIconDiscovery.swift`).

### Validation and safety

- Graftty accepts only an allowlisted subset of SVG: basic shapes, paths, groups, transforms, linear gradients and text. It rejects script, `foreignObject`, event attributes, external references, `<image>`, CSS imports and URLs other than local `#id` fragments.
- An oversized or invalid drawing is rejected with an error the agent can act on, and the previous icon stays.
- The Mac renders the drawing to PNG at the sizes it needs. Clients never parse agent SVG. Mobile receives PNG through the same revision-checked path project icons use (`PNGThumbnail`, `ProjectIconCache`, `iconRevision`).

### Display

The drawn icon replaces the emoji wherever a linked worktree's identity appears:

| Surface | Size |
|---|---|
| Mac sidebar row | 15 pt |
| Mac breadcrumb | 14 pt |
| Mobile list | 18 pt |
| Mobile header | 22 pt |
| Header wash watermark | 114 pt |
| Header wash blurred copy | 420 pt |
| Notifications | unchanged: they keep the emoji text |

`WorktreeIconIdentity` gains a drawn-icon case, used before `.emoji`. Home checkouts are unchanged.

## Constraints

- Public open-source repository. Fixtures and examples must not include private project names, paths or images. The previews used the user's real worktrees and must not be committed.
- Every behavior needs an EARS `@spec` and a RED/GREEN test (`CLAUDE.md`). Regenerate `SPECS.md`.
- `GrafttyKit` builds on Linux. SVG rendering is Apple-only, so a Linux host must still work. It can fall back to the emoji.
- Older Graftty clients and older agent skills must keep working. Recaps without a drawing remain valid, and older mobile clients keep showing the emoji.
- Mobile changes require iOS CI. macOS `swift test` misses UIKit-guarded code.
- Run `/code-review xhigh --fix` before opening a PR.

## Left to the builder

- **How the drawing is submitted:** a new recap field, or a separate command such as `graftty worktree icon --stdin` that keeps recaps brief. Recap fields are validated as brief text, which suggests the separate command.
- **The SVG renderer on macOS,** such as `NSImage` SVG support or a WebKit snapshot. Verify that gradients and the filter-free white edge render correctly.
- **How the white edge is produced,** for example by drawing the shape again with a dilated white outline before rasterizing.
- **The size limit and the exact allowlist.**
- **Where drawings and colors are stored.** They belong with the worktree entry, alongside `emoji` and `emojiSource`.
- **Lightness tiers** once a project's worktrees outnumber the hues that stay clearly distinct.
- **How the user overrides a drawing or color,** extending the existing manual emoji menu.

## Reference previews

These stay local and are not committed, because they show the user's private worktrees. They are in this session's scratchpad as `svg-spike/svg-icon-preview*.html`, versions 1–6.
