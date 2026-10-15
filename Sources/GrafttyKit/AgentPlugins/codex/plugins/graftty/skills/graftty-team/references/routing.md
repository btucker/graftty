# Routing details

Canonical paths and their provider or exact-agent suffixes can target any tracked local repository. Short worktree names resolve only within the caller's repository. To inspect another team:

```sh
graftty team members --worktree '<absolute-worktree-path>' --json
```

Copy its canonical address. For roster and inbox diagnostics, `--repo` filters repositories but does not override a tracked caller; use `--worktree` to select another repository's worktree.

Preserve complete `graftty-mac://...` addresses for remote recipients. A bare filesystem path targets the Mac running the command.

Older messages have `<graftty-peer-message agent="<exact-address>" fallback-agent="<runtime-address>">` without a reply command. Use `agent` unchanged if reachable in the roster; otherwise use `fallback-agent`. `<graftty-forge-message provider="<provider>">` and `<graftty-system-message>` are notices, not reply addresses.

Do not resolve Graftty recipients through provider-native `SendMessage` or `ListAgents`. Identical worktree names on different Macs can name different agents. If a native message supplies an explicit Graftty reply socket, use that socket unchanged, not a display name.

Forward misdirected messages to the correct roster address and state that you forwarded them. Do not impersonate another agent.
