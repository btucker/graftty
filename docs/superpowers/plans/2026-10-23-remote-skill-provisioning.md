# Remote skill provisioning

Skill capture, authenticated transfer, and staging are available for Claude and Codex. Automatic provisioning, container mounts, launch integration, full plugin installation, and settings reconciliation remain pending. The CLI reports `staged`, not agent readiness.

## Capture and stage

On the parent, capture the selected runtime's user skills and the selected worktree's root-level skills:

```sh
graftty remote skills export --runtime codex \
  --workspace /absolute/path/to/worktree --output /absolute/path/to/new-skills.json
```

The JSON response reports the content revision, runtime, file count, and export path. The output file is created with mode 0600 and never overwrites an existing file. The export includes supporting files and preserves executable flags. It does not read settings, plugin caches, authentication stores, or session history. Use `--source-home /path/to/home` to select another home explicitly; that option ignores the current process's runtime-home overrides.

To transfer and stage it through the running parent app's authenticated connection:

```sh
graftty remote skills sync --host <paired-host-name-or-device-id> \
  --repository /registered/repository/on/worker \
  --input /absolute/path/to/new-skills.json --revision <revision-from-export> \
  --operation-id <stable-uuid>
```

This requires updated builds of the parent app and Linux host. The CLI resolves the host once and pins its device ID and fingerprint on every request. The SSH receiver rechecks current pairing, key identity, and worktree-management permission before each request. It derives the parent from that authenticated connection and requires the destination repository to remain registered. Skill staging is not relayed through another host and does not grant execution or MCP access.

After a lost reply, rerun with the same host, snapshot, revision, and operation UUID. The receiver returns its retained offset or staged acknowledgement. Conflicting arguments or chunk bytes are rejected. Transfers use chunks of at most 256 KiB, at most two active uploads and 48 MiB reserved bytes, and a five-minute retention window. Expiry and shutdown discard incomplete bytes. A worker restart requires sending the snapshot again; complete content revisions remain on disk. Aborted operations need a new UUID.

For local staging after a separately authenticated transfer, run on the destination:

```sh
graftty remote skills stage --input /absolute/path/to/skills.json \
  --revision <revision-from-parent-export> \
  --parent-id <authenticated-parent-id> --project-id <project-id>
```

The returned `userDirectory` and `projectDirectory` contain native relative directory layouts. Provisioning must place or mount these at the agent's actual home and worktree, including inside a Dev Container. They are not discovery roots merely because they exist in the staging store. `--directory` selects an alternate store. Parent and project arguments partition local storage; they do not authenticate a network sender. The future receiving service must derive these identities from the authenticated assignment.

## Scope and exclusions

Codex capture includes user `.agents/skills`, `${CODEX_HOME:-~/.codex}/skills`, and worktree `.agents/skills` and `.codex/skills`. Claude capture includes `${CLAUDE_CONFIG_DIR:-~/.claude}/skills` and worktree `.claude/skills`. The export records portable destination paths, never absolute source Mac paths. Hidden top-level skill directories, including bundled system skills, are not exported. Runtime and admin defaults remain the destination runtime's responsibility.

Each skill must have `SKILL.md`; supporting scripts, references, and assets travel with it. Links within a skill are materialized as regular files. A skill directory may link into another selected skill root of the same scope. Links outside these roots, links from supporting files outside their own skill, directory cycles, and special files fail capture. These restrictions can reject personal skills linked to an external dotfiles checkout; the error is explicit.

Known credential filenames, environment files, private-key formats, and Git metadata are rejected inside skill trees. This is not a general secret detector. Arbitrary credentials embedded in instructions or scripts cannot reliably be distinguished from ordinary skill content. Export only skill content intended for the selected worker. No skill is executed during capture or staging.

Snapshots are bounded to 4,096 files, 4 MiB per file, 16 MiB of content, and 24 MiB encoded. Paths and nesting are bounded; traversal, duplicate destinations, and file/directory conflicts are rejected before installation. Capturing a missing workspace fails rather than reporting an empty project. The sync command divides snapshots into bounded requests on the existing authenticated worktree-management channel; it never inserts a complete snapshot into a control frame.

## Revision lifecycle

A revision hashes canonical snapshot content, including runtime, scope, path, bytes, and executable flags. Parent/project identities partition the store without becoming filesystem paths themselves. Staging writes a private temporary tree and renames it into place only when complete. A failed stage leaves no published revision. Retrying verifies every existing file, its executable flag, and the complete tree before reusing it; altered revisions fail without overwriting the altered copy.

There is no mutable `current` link. A launch must retain the exact staged revision path. Changed or removed skills produce a different revision, while earlier revisions remain available. Garbage collection must wait until launch/session references are implemented. This layer deliberately does not delete old revisions or modify unrelated host configuration.

Keep runtime-owned files outside the snapshot. In particular, the installed Codex writes bundled `.system` skills into its runtime skills directory during discovery. Link or mount individual personal skills into a writable runtime skills directory; do not make the whole runtime directory a writable alias of the staged snapshot. The native discovery tests verify that initialization leaves the staged revision unchanged.

## Validation

`RemoteSkillSnapshotTests`, `RemoteSkillStoreTests`, and `RemoteSkillsCLITests` cover scope and runtime separation, native layouts, supporting files, executable flags, custom homes, deterministic revisions, escaping links, cycles, FIFO rejection, credential artifacts, malformed snapshots, byte limits, parent/project isolation, interrupted staging, tampered revisions, and CLI revision mismatch.

`RemoteSkillTransferTests` verifies peer fingerprint binding, registered repository checks, bounded chunks and quotas, conflicting retries, expiry, abort, runtime/revision mismatch, lost acknowledgements, and resumed offsets. CLI tests verify the destination device and fingerprint on every encoded request. Direct SSH loopback tests transfer a 700 KB payload through actual framed requests and verify the staged bytes; a separate test removes the trusted peer while its channel remains open and verifies that the next request is rejected before the receiver runs.

`RemoteSkillNativeDiscoveryTests` runs opt-in checks against actual staged snapshots. Set `GRAFTTY_TEST_CODEX_BINARY` and/or `GRAFTTY_TEST_CLAUDE_BINARY` to absolute native executable paths, then run `scripts/swiftpm test --filter RemoteSkillNativeDiscoveryTests`. Each probe owns an isolated runtime home and child process group, uses bounded protocol reads, and sends initialization/discovery requests only.

A local Codex app-server probe initialized an isolated runtime home and listed fixture skills without sending a model request. It discovered a skill in that home's `skills` directory with user scope and a worktree `.agents/skills` skill with repository scope. A separate Claude stream initialization, also using an isolated runtime home without a model request, returned both the personal and project fixture skills in its command list. Neither probe copied authentication material. These probes verify the installed runtimes' discovery behavior, not automatic remote provisioning, plugin compatibility, or Linux execution. The published [Codex skill documentation](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) describes `.agents/skills` discovery; [Claude's skill documentation](https://code.claude.com/docs/en/skills#choose-where-skills-load) describes its personal and project skill locations. Runtime-specific compatibility must be checked before activation.
