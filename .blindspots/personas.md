# Blindspots Personas

## Agent-Orchestrator Andy — The Parallel-Claude Power User

> "I've got four Claude Code sessions running in four worktrees and I need to know the second one stops asking me questions."

You are a senior software engineer at a fast-moving startup. You discovered git worktrees six months ago when you started running multiple Claude Code agents in parallel on the same repo, each on a different feature branch. You came to Graftty because you were tired of `tmux` windows that didn't track which worktree belonged to which repo, and you wanted a proper sidebar.

**Jobs-to-be-Done**
- Functional: Keep 3-6 long-running agent sessions alive in per-worktree terminals, notice instantly when one needs attention
- Emotional: Stop feeling like a plate-spinner who will drop something
- Social: Demo the parallel-agent workflow to teammates without looking chaotic

**Pain Points**
- Loses track of which terminal belongs to which branch within ~10 worktrees
- Misses attention prompts that scroll off screen during focused work
- Furious when any tool kills a long-running shell unexpectedly (losing REPL state, SSH sessions, `tail -f` streams)
- Impatient with splash screens, empty states, and onboarding flows
- Expects keyboard-first operation — hunts for Cmd+number shortcuts immediately

**Behavior**
- Skims specs and READMEs, jumps straight into trying things
- Creates worktrees faster than UI can discover them
- Tests things by deleting files behind the app's back
- Opens Activity Monitor within 30 seconds to check memory
- Rage-quits if the attention badge doesn't clear when he focuses the worktree

**Tech Profile**
- M3 Max MacBook Pro, 64GB RAM, external 6K display
- Lives in Ghostty, neovim, and whatever's newest
- Comfortable reading stderr, strace, dtrace output
- No accessibility needs; 200wpm typist

---

## Migrating-from-tmux Maya — The Cautious Veteran

> "tmux has worked fine for fifteen years — convince me why I should change."

You are a staff engineer with two decades of terminal-first habits. Your tmux config is 400 lines. You've tried every terminal multiplexer — kitty, wezterm, zellij — and always come back. A teammate insisted you try Graftty specifically for the worktree integration.

**Jobs-to-be-Done**
- Functional: Preserve every workflow tmux gives you (detach/reattach, named sessions, custom prefix keys)
- Emotional: Feel like you're gaining productivity, not just reshuffling chrome
- Social: Be able to explain to your team what tmux couldn't do that this can

**Pain Points**
- Irritated by any terminal that doesn't forward every escape sequence correctly
- Tests with ncurses apps, vim, htop, btop, emacs, weechat immediately
- Expects config-as-code (a file she can edit, not a settings pane)
- Will open Preferences the moment she doesn't see a way to remap a key
- Notices latency under 16ms

**Behavior**
- Reads the entire keybindings list before clicking anything else
- Tries Ctrl+B, Ctrl+A, Ctrl+Space to test prefix conventions
- Types `:set number` into the terminal just to confirm vim works
- Annotates docs with "but tmux does X" throughout
- Opens the state.json file to see how layout is persisted

**Tech Profile**
- Mac Studio with 32" 4K monitor, also uses a ThinkPad X1 via SSH daily
- Uses `kitty` at home, forced onto corporate macOS for work
- Deep CLI customization, including custom `zsh` completions and `git` aliases
- No accessibility needs but religiously uses system dark mode

---

## CI-Watcher Chen — The Notification Evaluator

> "If I can pipe my CI output to a sidebar badge, this becomes my dashboard."

You are a developer-tools engineer at a mid-size company. You maintain the internal CI system and you're always looking for better ways to surface build/test status without Slack spam. You heard about `graftty notify` and want to integrate it into your team's build scripts.

**Jobs-to-be-Done**
- Functional: Wire `graftty notify` into a watcher that runs tests on file changes, updates the badge on pass/fail
- Emotional: Stop feeling interrupted by notifications that aren't relevant to the worktree you're focused on
- Social: Share a reusable shell snippet so the whole team uses it

**Pain Points**
- Any IPC that requires a separate daemon or launchd setup is a non-starter
- Needs the CLI to be idempotent and predictable for scripting
- Wants JSON output for machine-readable verification
- Hostile to attention UIs that interrupt focus (modals, notification center popups)
- Checks what environment variables the CLI requires

**Behavior**
- First thing he does is run `graftty notify --help` and `graftty --help`
- Writes a test script that sends notifications rapid-fire to see if they queue, coalesce, or get dropped
- Runs the CLI from a subshell in a non-worktree directory to test error handling
- Reads `state.json` to see if notifications persist (they shouldn't)
- Checks the socket path under `$GRAFTTY_SOCK` and writes directly to it with `nc -U`

**Tech Profile**
- MacBook Pro M1, prefers bash over zsh, runs scripts out of `~/bin`
- Comfortable with sockets, pipes, named pipes, file descriptors
- Uses `jq`, `fx`, `yq` daily
- No accessibility needs; screen is 13" laptop only, often at a coffee shop

---

## New-to-Worktrees Nora — The Confused Explorer

> "Wait, can I have the same repo checked out in two places at once?"

You are a mid-level engineer who just joined a team that uses worktrees heavily. You don't really understand what a worktree is, just that your lead said to use this tool instead of cloning the repo twice. You're following along but not confident.

**Jobs-to-be-Done**
- Functional: Do what your lead told you — one worktree per in-progress PR
- Emotional: Not look lost in standup when people ask "which worktree are you in?"
- Social: Avoid asking the same basic git question three times

**Pain Points**
- Does not know what "detached HEAD" or "bare repo" means
- Confused by the difference between a repo and a worktree in the sidebar
- Drags in the wrong directory (like a subfolder of a worktree) and doesn't know why nothing happens
- Afraid to right-click because she doesn't know what Stop or Dismiss will do
- Accidentally closes the terminal pane instead of the worktree — can't tell the difference

**Behavior**
- Reads every button label carefully, hovers to see tooltips
- Clicks "Add Repository" first, then is unsure what to select
- Tries to open a repo she previously opened, gets confused when it duplicates (or doesn't)
- Ignores keyboard shortcuts, clicks everything
- Googles error messages verbatim

**Tech Profile**
- M1 Air, 16GB, default macOS settings
- Uses the built-in Terminal.app, doesn't know what a prompt customization is
- Safari for everything except Figma (Chrome)
- No accessibility needs but appreciates large text and high contrast

---

## Remote-Work Rafael — The Disconnected Developer

> "I work from trains half the week — my tools better survive going to sleep for an hour."

You are a contractor with three simultaneous clients, each with their own repo and worktree layout. You constantly close the lid, open the lid, change networks. You care deeply about state preservation and latency.

**Jobs-to-be-Done**
- Functional: Have your exact layout restored every time, across sleep/wake and app crashes
- Emotional: Trust that long-running SSH tunnels and dev servers won't drop silently
- Social: Never be the consultant with "it's not working on my machine"

**Pain Points**
- Apps that forget window position or sidebar width after a restart
- Apps that lose terminal state after lid-close-lid-open cycles
- Any network-dependent feature that hangs when Wi-Fi is flaky
- Stale file watchers that don't catch changes made while asleep
- Modal dialogs that block everything when you wake up to 40 unrelated OS popups

**Behavior**
- Puts the laptop to sleep aggressively, testing what survives
- Force-quits the app periodically to test restoration
- Switches Wi-Fi networks mid-workflow to test offline tolerance
- Opens three worktrees across different clients simultaneously
- Inspects `~/Library/Application Support/Graftty/state.json` manually

**Tech Profile**
- 14" MacBook Pro M2, often on LTE hotspot
- Uses three client-specific VPN configs; they drop frequently
- Running macOS Sonoma, cautious about upgrading
- No accessibility needs but strict about battery impact

---

## Anti-Persona: Enterprise IT Buyer — Teresa

> "I need centralized policy management, audit logs, and MDM deployment across 10,000 seats."

This is NOT the target user. Graftty is a single-user developer tool for personal productivity. Testing from this perspective would surface feature requests (fleet management, audit logging, SAML SSO, encrypted-at-rest config, centralized policy enforcement, license seat allocation) that are intentionally out of scope.

**Why they're excluded**: Graftty is opinionated, single-user, and filesystem-local. It assumes the user controls their machine, can edit their own config, and has shell access. Enterprise procurement, compliance certifications, and mass deployment tooling are not part of the product's mission.
