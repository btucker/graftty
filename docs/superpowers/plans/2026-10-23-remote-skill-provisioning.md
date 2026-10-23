# Remote skill provisioning

Skill capture, authenticated transfer, revision staging, and explicit Dev Container placement are available for Claude and Codex. A placement can install staged skills and launch a native agent inside its container. Full plugin installation, settings reconciliation, automatic capture on every launch/resume, and session replication remain pending. Skill availability does not establish agent authentication or complete configuration parity.

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

The returned `userDirectory` and `projectDirectory` contain native relative directory layouts. Provisioning must place or mount these at the agent's actual home and worktree, including inside a Dev Container. They are not discovery roots merely because they exist in the staging store. `--directory` selects an alternate store. Parent and project arguments partition local storage; they do not authenticate a network sender. The authenticated receiver derives these identities from the connection; local staging labels cannot authorize a remote placement.

## Placement and agent launch

After export and authenticated sync, select the exact staged revision when creating the worktree:

```sh
graftty remote placement create --host <paired-host-name-or-device-id> \
  --operation-id <stable-placement-uuid> \
  --repository /registered/repository/on/worker --name task \
  --architecture arm64 --dev-container \
  --skill-revision codex:<revision-from-export> --agent codex
```

Repeat `--skill-revision` for Claude if both runtimes need skills. Omit `--agent` to open a shell with those skills available. An agent selection requires a matching revision. Install the native agent executable in the project's Dev Container configuration; Graftty checks that it exists before opening the pane, but does not install it or copy a login. Use `remote placement status` with the same host and placement UUID to inspect asynchronous setup.

The worker reloads and verifies the complete staged content using the authenticated parent's device and fingerprint plus the registered repository. Unknown, altered, or another parent's revisions fail before admission. The selection is part of the retained placement intent, so retries cannot change it. A distinct request type makes older workers reject skill-bearing placement rather than silently discard its options.

Installation uses `devcontainer exec` as the configured remote user, in the actual container workspace. Bounded shell commands carry file bytes as base64 data. The image needs POSIX shell utilities, `base64`, and `diff`. A private home holds writable native runtime directories, with each personal skill linked to its separate source directory. `HOME`, `CODEX_HOME`, and `CLAUDE_CONFIG_DIR` point to this profile in the opened shell and agent. Codex can create its bundled `.system` skills without writing into the selected personal skills.

Project skills retain their native worktree paths. Identical checked-in directories are reused. Missing project skills are copied as ordinary files, including executable flags, and can appear as untracked worktree changes. Conflicting content or symlink destinations fail setup without overwriting them. Sync the intended Git revision or select a matching snapshot before retrying with a new placement operation. Setup failure retains the worktree and reports an uncertain operation; it does not claim the agent started.

The profile path is retained with the prepared container and reused when reopening a pane. Each new placement gets its own profile; refreshing an existing worktree's active skill revision is still pending. Managed hosts keep profiles under their private `agent-profiles/<placement UUID>` directory and bind-mount only that placement directory through the upstream CLI. The same absolute path exists on the host and in the container. Setup verifies a fresh host-written mount probe and matching user IDs before installing skills. Existing directories must be owned by the host user with mode 0700; setup rejects symlinks, mismatched users, and invalid mount paths without changing ownership or relaxing permissions. Configure the Dev Container remote user to match the Linux host user.

Removing the container retains the profile and native session files on the host. Recreating a container for the same operation can access that retained directory, but automatic selection/resumption of an earlier profile is not implemented. Profiles are not deleted with the worktree, pending explicit retention and cleanup policy. Host loss still requires native session replication to the parent; this mount does not establish Spot recovery. No parent login is copied. Low-level preparer callers without a profile directory retain the earlier container-local behavior.

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

`DevContainerLiveSkillsTests` runs the production preparer, installer, launch shell, and cleanup against a real local Linux Docker engine. Put the official Dev Container CLI on `PATH`, set `GRAFTTY_TEST_DEVCONTAINER_IMAGE` to an image containing Git, POSIX shell utilities, `base64`, `diff`, and `useradd`, and run `scripts/swiftpm test --filter DevContainerLiveSkillsTests`. The disposable container is removed on success or failure. A local run passed with CLI 0.89.0 and `swift:6.2.3-noble`, verifying both runtimes' skill layouts, executable project files, isolated environment variables, Git access, and profile persistence across a stop/start. A second case builds a test user matching the host UID, deletes and recreates the container, and verifies retained profile files from both the host and replacement container. That probe uses an ordinary checkout; it does not establish linked-worktree or native Linux agent compatibility.

A local Codex app-server probe initialized an isolated runtime home and listed fixture skills without sending a model request. It discovered a skill in that home's `skills` directory with user scope and a worktree `.agents/skills` skill with repository scope. A separate Claude stream initialization, also using an isolated runtime home without a model request, returned both the personal and project fixture skills in its command list. Neither probe copied authentication material. These probes verify the installed runtimes' discovery behavior, not plugin compatibility or Linux execution. The published [Codex skill documentation](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) describes `.agents/skills` discovery; [Claude's skill documentation](https://code.claude.com/docs/en/skills#choose-where-skills-load) describes its personal and project skill locations. Runtime-specific compatibility must be checked before activation.
