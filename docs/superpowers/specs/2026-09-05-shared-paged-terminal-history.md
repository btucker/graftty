# Paged terminal history on Mac and mobile

Mac and mobile share the implemented paging contract. A terminal restores its
current screen before loading older scrollback. The active requirements and
behavioral tests are generated into [SPECS.md](../../../SPECS.md) from `@spec`
annotations.

The dependency fork now owns the native engine pin, paging patches, Swift wrapper,
compiled archives, and build provenance. Development, CI, and release builds
consume one published package revision. Graftty retains an explicit local override
for dependency development, validated against that package's own receipt. See the
[dependency build instructions](../../../scripts/ghostty-paging/BUILD.md).
The engine snapshot format and zmx producer remain unchanged by this consolidation.

The [original experiment results](../../../scripts/ghostty-paging/RESULTS.md)
record the incremental-history investigation on AppKit and UIKit. Its native
probes and patch stack have moved into `btucker/libghostty-spm/Paging`. The design
sections below explain the attachment and recovery boundaries.

## Opening time must not depend on the entire history

A cold open restores the current terminal state and a bounded amount of recent
history. Older pages arrive when the reader approaches the oldest loaded
content. An already mounted, connected Mac pane keeps its current attachment.

The first milestone covers local Mac panes, remote Mac panes, and mobile panes.
It includes in-memory retention of fetched pages. Durable on-device caching and
resume from acknowledged output positions remain later work. The existing
PERSIST-4.1 and IOS-8.4 restrictions on persisting terminal history remain intact.

The acceptance fixture contains 100,000 uniquely numbered short lines, with test
retention limits large enough to keep every line. With older-page responses withheld, both
apps must display the current screen and exchange live input and output. When
responses resume, scrolling must reveal each retained line once, in order.

## Existing snapshots provide part of the mechanism

The current paths ultimately feed VT output into a Ghostty surface:

- Local Mac uses `HostManagedZmxBackend` and `NativePtySession`.
- Remote attaches use `ZmxAttachEngine`, with authenticated terminal channels
  consumed by mobile `SessionClient` and the Mac remote terminal backend.
- Regular zmx attaches decode the snapshot, consume all history, and serialize
  the result back to VT. See the [zmx integration notes](../../../scripts/zmx/README.md).

The zmx pin `ccf8e9f43a946a86a1aac0c4e4944f4884a12d54` uses Ghostty
`8af6897c0afc63037a8a3efee4162a380e3a4572`. Its
[snapshot C API](https://github.com/ghostty-org/ghostty/blob/8af6897c0afc63037a8a3efee4162a380e3a4572/include/ghostty/vt/snapshot.h)
already separates a renderable `READY` prefix from history records, ordered
newest first, and a final `FINISH` record. The decoder permits live output
between page imports.

There are four integration constraints:

1. The VT snapshot API returns a terminal object. Graftty needs a bridge into
   its existing rendered surface, including renderer invalidation and ownership
   of the restored parser. The current surface API does not expose that bridge.
2. Raw `zmx attach --snapshot` still places all history before subsequent live
   bytes. Pausing that stream after `READY` also blocks live output.
3. The current encoder synchronously exports a complete snapshot. Splitting
   the resulting buffer into pages saves neither initial encoding time nor
   host memory. Demand encoding requires a consistent, bounded history view.
4. The current decoder discards pending history after a resize. It can also
   validate a page while importing zero rows. Consuming a record is not proof
   that its content became available to the reader.

The format is experimental and has no binary compatibility guarantee. The
surface library and zmx also use different Ghostty revisions. Paging therefore
requires explicit codec compatibility negotiation and cross-version fixtures.

## Shared responsibilities

| Component | Responsibility |
| --- | --- |
| zmx daemon | Capture a consistent screen and history boundary; serve retained pages; order live output after that boundary. |
| Host attachment adapter | Expose typed checkpoint, output, and history messages; enforce resource limits and schedule live traffic ahead of bulk history. |
| GrafttyProtocol | Define negotiated message shapes, identities, page positions, limits, and error responses for both apps. |
| Shared client coordinator | Request contiguous pages, reject stale replies, deduplicate retries, and manage bounded in-memory retention. |
| Ghostty surface bridge | Import state and prepend history without recreating the mounted renderer or moving the reader's content. |
| AppKit and UIKit adapters | Detect proximity to unloaded history, expose loading or retry UI, and apply platform memory budgets. |

The client coordinator must be usable from both Mac and mobile targets. It must
not live only inside `GrafttyMobileKit`. Platform scroll callbacks report demand
to this coordinator rather than constructing protocol messages themselves.

## Checkpoints and pages have explicit identities

The proposed attachment envelope identifies a session incarnation, checkpoint,
snapshot codec, authoritative grid, and ordered output boundary. A session
incarnation changes when the daemon session is recreated, even if its name is
reused. A checkpoint changes when the captured terminal state is replaced.

History requests name that checkpoint, the screen, the expected next page
position, a request identifier, and a byte budget. Replies echo those identities
and distinguish a page, completion, expiration, and failure. Ordinals identify
pages within a checkpoint; viewport row numbers do not identify content across
resizes or checkpoints.

The host retains a consistent history view for the checkpoint. The exact
mechanism needs a prototype: immutable or copy-on-write page retention is a
candidate, not an assumed capability of the current encoder. Pinning every
client's complete history indefinitely is unacceptable. Resource accounting,
checkpoint expiration, and release on disconnect belong to this mechanism.

A client imports only the next expected page. Duplicate responses do not cause
another prepend. Replies from older checkpoints are ignored. Ordered loading
fits the existing decoder and bounds buffering; random access is outside this
first milestone.

Output represented by the checkpoint is never delivered again as live output.
Subsequent output remains ordered, including resizes and parser continuations.
An output sequence position here defines the checkpoint cut; it does not yet
promise reconnect resume from a durable client acknowledgement.

## Live traffic cannot wait for a history reader

Checkpoint installation precedes live bytes. After installation, history and
live output are independent typed messages. Binary snapshot bytes never pass
through the VT parser as ordinary terminal output.

For remote connections, an independent authenticated history channel is the
preferred first experiment. The host still needs bounded chunks and priority
scheduling because channels can share a lower-level connection. A local Mac
adapter offers the same logical separation through zmx IPC.

The synchronous snapshot reader must never block on network data while holding
the terminal or renderer lock. The bridge waits for sufficient validated data
outside that lock, then performs a bounded import operation. EOF cannot represent
temporary starvation: the current decoder treats a zero-byte read as truncation.

Input eligibility continues to follow existing connection and display ownership
rules. Loading history neither takes ownership nor resizes the remote PTY.

## Reflow and reading position are correctness requirements

Prepending a page preserves a content anchor and any selection. A reader at the
live bottom continues following output. A reader in older content stays there
while new output arrives below. Anchors cannot be raw viewport offsets because
prepends and reflow change those offsets.

Resize-aware history import is the first renderer experiment. It must keep
older retained content reachable after phone rotation and Mac window resizing.
The existing decoder's zero-row result must trigger explicit recovery, never
successful completion of a page request.

Compatibility must account for intervening reflows, not just the current grid.
Resizing from 80 to 40 columns and back to 80 does not make old page boundaries
valid again. Stop before consuming an incompatible page and keep the loaded
terminal usable while recovery is pending. Height-only changes do not invalidate
encoded column widths.

If safe reflow needs a replacement checkpoint, recovery must preserve the
reader's content or make the transition explicit. Silently resetting the screen
on every resize would undo the intended reading experience. The choice between
reflow-aware page insertion and checkpoint recovery stays open until measured
against real Ghostty surfaces.

The native experiment now covers this invalidation boundary on both platforms.
It does not yet recover a checkpoint. Ghostty currently reflows the full loaded
page list, and a wrapped logical line can cross a page boundary. Reflowing each
incoming page independently therefore needs an explicit boundary-joining rule.
Reflowing the whole loaded terminal after each import would also make page cost
grow with loaded history. Neither approach meets the bounded-import requirement
without more work.

Memory pressure may evict unpinned cache pages. Visible or selected content
cannot disappear silently. Whether imported pages can be evicted and reloaded
without rebuilding the terminal is another requirement for the surface bridge.

## Implementation proceeds through working integrations

1. **Ghostty bridge experiment.** Restore `READY` into actual AppKit and UIKit
   surfaces, apply live output, and prepend one history page. Verify selection,
   alternate-screen transitions, and resize before adding Graftty protocol types.
   Extend or align the dependency revisions where the current API is insufficient.
2. **zmx paging experiment.** Capture the checkpoint cut and expose page requests
   without encoding the complete history on attach. Keep live output flowing
   while the history consumer is stopped. Measure daemon pause time and retained
   memory with multiple clients.
3. **Shared client and Mac integration.** Add the negotiated protocol and shared
   coordinator, then wire local and remote Mac attaches. Preserve the mounted
   pane selection path. Use the existing VT path for incompatible peers.
4. **Mobile integration.** Reuse the coordinator and import bridge, connect scroll
   demand, and set mobile memory and prefetch budgets from measurements.
5. **Combined acceptance.** Run the same numbered-history fixtures on both apps,
   including one client resizing while another loads history.

Tests move from the disabled TERM-12 inventory into real behavioral tests as
each integration is implemented. Passing tests for message shapes alone does
not complete the milestone.

## Evidence required before enabling paging

The test matrix covers these cases:

- Cold opens at increasing retained-history sizes, with older-page delivery
  withheld. Record bytes and encoding work before the first usable screen.
- Live output and authorized input during delayed or failed page requests.
- Duplicate replies, canceled requests, reconnects, expired checkpoints, and a
  restarted daemon using the same session name.
- Numbered lines spanning multiple pages, including overlap resident before
  `READY`, to detect gaps, repetition, and reordering.
- Phone rotation, Mac resizing, ownership changes, primary and alternate screens,
  explicit history clearing, and split UTF-8 or VT sequences at the checkpoint.
- Selection and content anchors during prepend, live output, and memory pressure.
- Old clients with new hosts, new clients with old hosts, and mismatched codecs.
- Repeated open and close cycles with several clients to verify resource release.

Performance results separate connection setup, checkpoint capture, first usable
screen, page latency, and host and client memory. Success requires bounded
initial work as history grows; a faster full replay does not meet TERM-12.1.
