# One Project Across Hosts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task (the user chose native execution). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Same-origin checkouts appear as one project on Mac, iPhone and iPad, with a mixed worktree list, no host selector, a host choice in Add Worktree, synced pinned and project order, and hosts that wake only when an interaction needs them.

**Architecture:** Hosts publish new optional fields (origin key, activity time, ranks). All merging is pure client-side logic in `GrafttyProtocol`, shared by Mac and mobile and tested on macOS with `scripts/swiftpm test`. Mac and mobile views consume its output, and each row keeps its owning host's route, so every management request still goes to one host.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing, SwiftPM through `scripts/swiftpm`.

**Spec:** `docs/superpowers/specs/2026-11-03-multi-host-projects-design.md`. Mocks: `docs/design-spikes/multi-host-projects/options.html`.

## Global Constraints

- Every new wire field is optional and decodes as nil from older hosts. Older hosts and clients keep working.
- Two checkouts are the same project when their normalized `origin` is equal, using `GitRepositoryOrigin`. No origin, older hosts and forks stay separate. `upstream` is never compared.
- Hosts never connect to each other for this feature.
- No repeated per-row host decoration on temporary worktrees, and no selector or filter hiding another host's work.
- Status-line order: question, `graftty notify` text, agent working, `brief.completed`, name only. "Active" means working or needing input.
- Use subtle status cues: dim and italic, not saturated color.
- `SPECS.md` is generated. Write `@spec` EARS requirements in test titles, with no literal double quotes in titles. Run `scripts/generate-specs.py`. Delete retired specs with their tests.
- Use `scripts/swiftpm` for all SwiftPM commands, and never `--skip-build`. `swift test` on macOS doesn't compile UIKit-guarded code, so mobile tasks also need the iOS simulator compile.
- This is a public repository. Host names, paths and tokens in tests are invented.
- New spec IDs continue from `LAYOUT-2.199`, `REMOTE-2.33`, `REMOTE-13.32` and `IPAD-1.33`.

## Review Focus

1. **Wake requested while a non-wake dial is in flight or in cooldown:** tapping a sleeping worktree must still send the wake, not join the quiet attempt or get swallowed by the failure cooldown. Tests in Task 7.
2. **First-run rank ties:** every host seeds ranks from its own order, so ties are normal. Dragging between two tied rows must land exactly there on every device. Tests in Task 2.
3. **A selected project or worktree whose host vanishes:** the merged project stays selected and shows the remaining rows. It doesn't jump to another project or leave a blank detail. Tests in Task 3 and Task 8.
4. **Older host in a merged sidebar:** a host with no key, rank or activity time still shows all its rows, in stable positions, with no crash or dropped rows. Tests in Task 3 and Task 4.
5. **Mac reached directly and through another Mac:** each row appears once, using the direct route, and the row doesn't flicker or lose selection when the relay disappears. Tests in Task 4.

---

## Phase 1: Shared logic

### Task 1: Wire fields and requests

**Files:**
- Modify: `Sources/GrafttyProtocol/SidebarNavigation.swift`
- Modify: `Sources/GrafttyProtocol/WorktreeManagementEnvelope.swift`
- Test: `Tests/GrafttyProtocolTests/MultiHostWireTests.swift`

**Interfaces:**
- Produces on `SidebarProject`: `originKey: String?`, `rank: String?`, `rankChangedAt: Double?`.
- Produces on `SidebarWorktreeMetadata`: `activityTime: Double?`, `pinnedRank: String?`.
- Produces on `RemoteRepositoryInfo`: `originKey: String?`.
- Produces on `WorktreeManagementRequest`: `.setPinnedRank(repositoryID: String, worktreeID: String, rank: String)` encoded as `set_pinned_rank`, and `.setProjectRank(repositoryID: String, rank: String, changedAt: Double)` encoded as `set_project_rank`.

- [ ] **Step 1: Write failing tests:** `olderPayloadDecodesNewFieldsAsNil`, `newFieldsRoundTrip`, `setPinnedRankRoundTrips`, `setProjectRankRoundTrips`.
- [ ] **Step 2: Run them:** `scripts/swiftpm test --filter MultiHostWireTests`. Expected: FAIL to compile.
- [ ] **Step 3: Add the fields as trailing defaulted init parameters** so existing call sites compile, and add the two request cases.
- [ ] **Step 4: Run them.** Expected: PASS. Fix exhaustive switches the compiler flags in `GrafttyApp+WebRTCHostChannels.swift` and `RemoteMacsModel.swift` by returning an `unsupported` error until Task 6.
- [ ] **Step 5: Commit.**

### Task 2: Fractional ranks

**Files:**
- Create: `Sources/GrafttyProtocol/FractionalRank.swift`
- Test: `Tests/GrafttyProtocolTests/FractionalRankTests.swift`

**Interfaces:**
- Produces: `FractionalRank.seed(index: Int) -> String`, `FractionalRank.between(_ lower: String?, _ upper: String?) -> String`, `FractionalRank.isValid(_:) -> Bool`.
- Produces: `RankPlacement.Row { id: String, rank: String?, isWritable: Bool }` and `RankPlacement.move(_ id: String, toIndex: Int, in rows: [Row]) -> [RankPlacement.Write]`, where `Write { id: String, rank: String }`.

Ranks are base-62 strings compared by UTF-8 bytes. `seed` gives increasing fixed-width strings with gaps.

- [ ] **Step 1: Write failing tests:** `betweenSortsStrictlyBetween`, `betweenWithNilBounds`, `thousandInsertsInOneGapStaySortedAndUnderTwoHundredBytes`, `seedsAscend`, `moveBetweenDistinctNeighborsWritesOneRow`, `moveBetweenTiedNeighborsLandsExactlyThere`, `moveAroundUnwritableTiedRowStillOrdersWritableRows`, `moveToOwnPositionWritesNothing`, `invalidOrLegacyRankTreatedAsNil`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** `move` normally returns one write. When the neighbors tie, or the upper neighbor has no rank, it also rewrites the writable rows in the tied run so the result sorts as requested.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 3: Project merge

**Files:**
- Create: `Sources/GrafttyProtocol/MergedProjects.swift`
- Test: `Tests/GrafttyProtocolTests/MergedProjectsTests.swift`

**Interfaces:**
- Produces: `HostAvailability` enum: `.reachable`, `.asleep`, `.offline`.
- Produces: `MergedProject { id: String, name: String, members: [SidebarProject], availability: HostAvailability, rank: String?, rankChangedAt: Double?, representative: SidebarProject }`. `id` is `origin:<originKey>` when keyed, otherwise the member's `id`. `representative` is a `SidebarProject` with the merged `id`, for `ProjectNavigationRail`.
- Produces: `ProjectMerge.merge(_ projects: [SidebarProject], availability: (SidebarProject) -> HostAvailability, localDeviceID: RemoteDeviceID?) -> [MergedProject]`, sorted.
- Produces: `ProjectMerge.repairs(_ merged: [MergedProject], isReachable: (SidebarProject) -> Bool) -> [(member: SidebarProject, rank: String, changedAt: Double)]`.
- Produces: `ProjectMerge.memberToMergedID(_ merged: [MergedProject]) -> [String: String]`.

Rules from the spec: newest `rankChangedAt` wins; a timed rank beats an untimed one; between untimed ranks, lowest wins; ties break on project id. Rankless projects from older hosts sort last, in their incoming order. Same-named projects with different keys show `owner/name`, taken from the origin key. The icon and `iconRevision` come from the local member, otherwise the first member that has one. Availability is reachable if any member is; asleep if any is asleep; otherwise offline.

- [ ] **Step 1: Write failing tests:** `sameKeyMergesAcrossHosts`, `twoCheckoutsOnOneHostMerge`, `noKeyStaysSeparate`, `differentKeysSameNameShowOwner`, `newestRankWins`, `timedBeatsUntimed`, `lowestUntimedWins`, `olderHostProjectsSortLastAndAreNotDropped`, `availabilityPrefersReachableThenAsleep`, `idStableWhenAHostDisappears`, `repairsTargetOnlyReachableStaleHosts`, `iconPrefersLocalMember`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 4: Merged worktree list

**Files:**
- Create: `Sources/GrafttyProtocol/MergedWorktreeList.swift`
- Test: `Tests/GrafttyProtocolTests/MergedWorktreeListTests.swift`

**Interfaces:**
- Produces: `MergedWorktreeRow { row: WorktreePanes, hostID: RemoteDeviceID?, hostLabel: String, showsHostLabel: Bool, availability: HostAvailability, relativeName: String }`.
- Produces: `MergedWorktreeNode` enum: `.row(MergedWorktreeRow)`, `.folder(id: String, name: String, children: [MergedWorktreeNode])`.
- Produces: `MergedWorktreeList.build(rows: [WorktreePanes], availability: (WorktreePanes) -> HostAvailability, hostHasProjectOnSeveralHosts: Bool) -> (pinned: [MergedWorktreeNode], temporary: [MergedWorktreeRow])`.
- Produces: `MergedWorktreeList.deduplicated(_ rows: [WorktreePanes]) -> [WorktreePanes]`, keeping the lowest `origin.relayDepth` for each owner and worktree.

Rules: temporary rows sort by `activityTime` newest first, with no-activity and stale rows last, flat, showing the full relative name. Pinned rows put default checkouts first, sorted by host name, then sort by rank with ties on host and path; older hosts' rankless pins stay last in host order. Folders use `sidebar.folders`, merge by path across hosts when at least two members share it, and sit at their highest-ranked member. Folders in `sidebar.folderIDs` that differ from the joined path are inferred and stay per host, showing the host. Host labels: pinned always when the project is on several hosts; temporary only on a name clash; never on single-host projects. Sleeping temporary rows carry `availability == .asleep`, and the label stays hidden unless there's a clash.

- [ ] **Step 1: Write failing tests:** `temporaryRowsMixAcrossHostsByActivity`, `temporaryIsFlatWithFullName`, `hostLabelOnlyOnClashForTemporary`, `hostLabelAlwaysOnPinnedWhenMultiHost`, `noLabelsOnSingleHost`, `pinnedSortsByRankAcrossHosts`, `defaultCheckoutsFirstByHostName`, `foldersMergeAcrossHosts`, `twoMemberMinimumCountsAcrossHosts`, `inferredFoldersStayPerHost`, `olderHostRowsKeptWithoutActivityOrRank`, `directRouteWinsOverRelay`, `dedupKeepsRowWhenOnlyRelayRemains`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 5: Status line

**Files:**
- Create: `Sources/GrafttyCommandUI/SidebarRowStatus.swift`
- Test: `Tests/GrafttyCommandUITests/SidebarRowStatusTests.swift`

**Interfaces:**
- Produces: `SidebarRowStatus` enum: `.question(String, paneID: String?)`, `.notification(String, paneID: String?)`, `.working(String)`, `.whereWeAre(String, isUnread: Bool)`, `.none`.
- Produces: `SidebarRowStatus.resolve(context: SidebarWorktreeContext, worktree: WorktreePanes, isAsleep: Bool) -> SidebarRowStatus`.

Several working agents give "N agents working". An idle agent at its prompt isn't active. `isAsleep` skips working and question states, because nothing is known to be running, and returns the cached `brief.completed`.

- [ ] **Step 1: Write failing tests:** `questionBeatsNotification`, `notificationBeatsWorking`, `workingBeatsWhereWeAre`, `oneAgentShowsItsTitle`, `twoAgentsShowCount`, `idleAgentShowsWhereWeAre`, `unreadStopIsMarkedUnread`, `noBriefGivesNone`, `asleepShowsCachedBriefOnly`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.**

## Phase 2: Hosts and connections

### Task 6: Publish and store

**Files:**
- Modify: `Sources/GrafttyKit/Model/RepoEntry.swift`, `WorktreeEntry` model, `Sources/GrafttyKit/Model/SidebarHostNavigation.swift`
- Modify: `Sources/GrafttyKit/Git/GitRepositoryOrigin.swift`
- Modify: `Sources/Graftty/Views/SidebarHostController.swift`, `Sources/Graftty/App/GrafttyApp+WebRTCHostChannels.swift`, `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift`, `RemoteWorktreeRelayRouter.swift`
- Test: `Tests/GrafttyKitTests/SidebarHostNavigationTests.swift`, `Tests/GrafttyKitTests/Git/GitRepositoryOriginTests.swift`, `Tests/GrafttyTests/` relay tests

**Interfaces:**
- Consumes: Task 1 fields, Task 2 `FractionalRank`.
- Produces: `GitRepositoryOrigin.identityKey: String`, equal for forms the type treats as equal.
- Produces: persisted `RepoEntry.originKey`, `.projectRank`, `.projectRankChangedAt`, and `WorktreeEntry.pinnedRank`, all optional.
- Produces: `SidebarHostNavigation.seedRanks(in: inout [RepoEntry], projectOrder: [String])`, `.setPinnedRank(_:worktreeID:repositoryID:in:) -> Bool`, `.setProjectRank(_:changedAt:repositoryID:in:) -> Bool`, `.activityTime(for: WorktreeEntry) -> Double?`.

- [ ] **Step 1: Write failing tests:** `identityKeyEqualAcrossSSHAndHTTPS`, `identityKeyDiffersForForks`, `seedRanksFollowCurrentOrderWithoutTime`, `seedKeepsExistingRanks`, `setPinnedRankRejectsUnknownRow`, `setProjectRankKeepsNewestTime`, `metadataPublishesActivityAndRank`, `olderStateJSONDecodes`, `relayForwardsRankRequestsToOwner`, `relayKeepsOriginKeyAndRanks`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** Refresh `originKey` when repos load and when `GitRepositoryOrigin.detect` reruns, off the main actor. Publish the new fields from `SidebarHostController.project(for:owner:)`, `SidebarHostNavigation.metadata(for:...)` and the repository list. Handle both new requests in the host switch and forward them in `sendRelayedWorktreeManagement` after route translation. Keep accepting `moveProject`, `moveWorktree` and `setWorktreeOrder` from older clients.
- [ ] **Step 4: Run them, then the full suite:** `scripts/swiftpm test`. Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 7: Explicit wake

**Files:**
- Modify: `Sources/GrafttyRemoteClient/Remote/RemoteHostDialer.swift`
- Modify: `Sources/Graftty/Remote/MacToMac/RemoteMacConnectionRegistry.swift`, `RemoteMacsModel.swift`
- Modify: `Sources/GrafttyMobileKit/Remote/RemoteConnectionCoordinator.swift`
- Test: `Tests/GrafttyRemoteClientTests/`, `Tests/GrafttyTests/` registry tests, `Tests/GrafttyMobileKitTests/` coordinator tests

**Interfaces:**
- Produces: `RemoteHostDialer.negotiate(..., allowsWake: Bool)` with no default, so every caller decides.
- Produces: `RemoteMacsModel.connect(to:allowsWake: Bool = false)`. `connectFromUserSelection` and explicit reconnect pass true.
- Produces: `RemoteConnectionCoordinator.connection(for:replacingExistingConnection:allowsWake: Bool = false)`.

- [ ] **Step 1: Write failing tests** (update `REMOTE-2.12`): `quietDialSendsNoWake`, `wakeDialSendsWake`, `wakeRequestDuringQuietAttemptDialsAgainWithWake`, `wakeRequestBypassesFailureCooldown`, `quietRequestStillHonorsCooldown`, `launchReconnectDoesNotWake`, `userSelectionWakes`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** A wake request that finds an in-flight quiet attempt awaits it, then dials again with wake if it failed.
- [ ] **Step 4: Run them and compile mobile tests for the simulator.** Expected: PASS.
- [ ] **Step 5: Commit.**

## Phase 3: Mac

### Task 8: Merged rail and mixed list

**Files:**
- Modify: `Sources/Graftty/Views/SidebarView.swift`, `RemoteMacsSection.swift`, `SidebarHostController.swift`
- Modify: `Sources/GrafttyCommandUI/SidebarNavigationState.swift`
- Create: `Sources/Graftty/Views/SidebarMergedRows.swift`
- Test: `Tests/GrafttyTests/` sidebar projection tests

**Interfaces:**
- Consumes: `ProjectMerge`, `MergedWorktreeList`.
- Produces: `SidebarMergedRows.make(local:remote:availability:localDeviceID:)`, returning merged projects and rows by merged project ID.
- Produces: `RemoteMacsSection.remoteWorktreeBlock` made internal so one row can render outside its section.

`navigation.selectedProjectID` holds merged IDs. Rail counts are re-keyed through `memberToMergedID`. Each row renders with `worktreeBlock` when its host is local, otherwise with `remoteWorktreeBlock`. Migrate saved selected and remembered project IDs through `memberToMergedID` so selection survives the upgrade. With the project column off, group rows under project names and retire the Remote Hosts section.

- [ ] **Step 1: Write failing tests:** `localAndRemoteSameOriginShareOneRailEntry`, `railCountsCoverAllHosts`, `selectionSurvivesWhenOneHostLeaves`, `savedMemberSelectionMigratesToMergedID`, `projectColumnOffGroupsByProject`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests, then launch a dev instance with the isolated recipe and screenshot the sidebar.** Expected: PASS, and one mixed list.
- [ ] **Step 5: Commit.**

### Task 9: New rows

**Files:**
- Modify: `Sources/Graftty/Views/SidebarView.swift`, `RemoteMacsSection.swift`, `WorktreeRow.swift`, `Sources/GrafttyCommandUI/SidebarWorktreeRows.swift`
- Modify: `Sources/Graftty/Terminal` context menu file that hosts `TERM-8.10`
- Delete: pane drag source (`TransferablePaneSlotID` use in sidebar), pane menu, order control, `PWD-1.4`, `PWD-1.5`, `LAYOUT-2.10`, order-mode specs
- Test: `Tests/GrafttyTests/` row tests

**Interfaces:**
- Consumes: `SidebarRowStatus`, `MergedWorktreeRow`.
- Produces: `SidebarStatusLine(status:theme:onOpen:)`.

The status line replaces pane rows. The hand moves to the worktree name. `SidebarHostNavigation.displayedWorktrees` always uses recent activity. The order control is removed, leaving Add worktree on that line. Temporary rows are flat with their full name; folders render only in Pinned Agents. Copy web URL moves to the terminal context menu. Host labels sit after the name.

- [ ] **Step 1: Promote or edit `@spec` tests:** `rowShowsOneStatusLine`, `noPaneRowsRendered`, `temporaryListHasNoFolders`, `pinnedKeepsFolders`, `recentActivityIsAlwaysUsed`, `copyWebURLInTerminalMenu`, plus deletion of retired specs.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests, screenshot, regenerate specs.** Expected: PASS, and it matches the mock.
- [ ] **Step 5: Commit.**

### Task 10: Drag with ranks

**Files:**
- Modify: `Sources/Graftty/Views/SidebarView.swift`, `RemoteMacsSection.swift`, `TransferableWorktreeMove.swift`, `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift`
- Test: `Tests/GrafttyTests/` drag tests

**Interfaces:**
- Consumes: `RankPlacement.move`, `.setPinnedRank`, `.setProjectRank`, `ProjectMerge.repairs`.
- Produces: `RemoteMacsModel.setPinnedRank(...)`, `.setProjectRank(...)`.

Pinned drags work across hosts within siblings. Rail drags send the rank and time to each reachable member, and wake the last-used host only if none is reachable, restoring the old position on failure. Repairs run after each sidebar refresh. A drop from a rankless older host falls back to `moveWorktree` or `moveProject`.

- [ ] **Step 1: Write failing tests:** `pinnedDragAcrossHostsWritesOnlyDraggedHost`, `pinnedDragStaysAmongSiblings`, `railDragWritesAllReachableMembers`, `railDragDoesNotWakeWhenOneReachable`, `railDragWithAllAsleepWakesLastUsed`, `failedWakeRestoresPosition`, `repairCopiesNewestOnce`, `olderHostFallsBackToMove`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 11: Open worktree header

**Files:**
- Modify: `Sources/Graftty/Views/BreadcrumbBar.swift`, `Sources/Graftty/Views/MainWindow.swift`, context panel heading
- Test: `Tests/GrafttyTests/` breadcrumb tests

**Interfaces:**
- Produces: `WorktreeHostLabel.text(isLocal:hostLabel:projectIsOnSeveralHosts:) -> String?` in `GrafttyProtocol`. Remote returns the host; local returns "This Mac" only when the project is on several hosts.

The label goes in the breadcrumb after the worktree name, before the chevron. Port chips follow the PR button, covering every pane, and extras collapse into a menu. Retire `PORTS-3.4` and the pane-row wording in `PORTS-3.x`.

- [ ] **Step 1: Write failing tests:** `remoteAlwaysShowsHost`, `localShowsThisMacOnlyWhenMultiHost`, `headerChipsCoverEveryPane`, `extraChipsCollapse`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests and screenshot.** Expected: PASS, and it matches the mock.
- [ ] **Step 5: Commit.**

### Task 12: Add Worktree host row

**Files:**
- Modify: `Sources/Graftty/Views/AddWorktreeSheet.swift`, `AddWorktreeFormController` file, `SidebarView.swift`, remote add-worktree sheet presentation in `MainWindow.swift`
- Create: `Sources/GrafttyProtocol/AddWorktreeHostChoice.swift`
- Test: `Tests/GrafttyProtocolTests/AddWorktreeHostChoiceTests.swift`, `Tests/GrafttyTests/` form tests

**Interfaces:**
- Produces: `AddWorktreeHostChoice { id, label, path?, availability }`.
- Produces: `AddWorktreeHostChoice.defaultChoice(_ choices:, lastUsedID:) -> (choice, wakesOnOpen: Bool)`.

The row is first and hidden with one host. Two checkouts on a host show `host · path`. Offline hosts are disabled, and choosing a sleeping host wakes it. Changing host keeps the typed name and clears a selected branch missing on the new host. Last used is stored per project on the device.

- [ ] **Step 1: Write failing tests:** `defaultsToLastUsed`, `sleepingLastUsedDefersToAwakeHost`, `allAsleepWakesLastUsed`, `offlineDisabled`, `hiddenForOneHost`, `switchingKeepsNameAndClearsMissingBranch`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.**

### Task 13: Sleeping hosts and per-host actions

**Files:**
- Create: `Sources/GrafttyRemoteClient/Remote/HostSnapshotCache.swift`
- Create: `Sources/Graftty/Views/WakingWorktreeView.swift`
- Modify: `RemoteMacsModel.swift`, `MainWindow.swift`, `SidebarView.swift`
- Test: `Tests/GrafttyRemoteClientTests/HostSnapshotCacheTests.swift`, `Tests/GrafttyTests/`

**Interfaces:**
- Produces: `HostSnapshotCache.save(hostID:projects:rows:)`, `.load(hostID:)`, `.remove(hostID:)`, stored in the app's support directory.
- Produces: `WakeFlow` state: `.asleep`, `.waking`, `.failed`.

Hosts with verified wake addresses keep cached rows, dim and marked asleep. Cached rows aren't relayed. Other unreachable hosts hide their rows and show the dim offline line. A click, question tap or notification wakes the host. A restored selection shows Wake instead of waking. Forgetting a host removes its cache. Pull and Remove in the project menu become per host.

- [ ] **Step 1: Write failing tests:** `cacheRoundTrips`, `forgetRemovesCache`, `sleepingRowsKeptOnlyWithWakeAddresses`, `cachedRowsNotRelayed`, `clickWakes`, `restoreDoesNotWake`, `failureOffersTryAgain`, `offlineLineForOtherHosts`, `projectActionsNamePerHost`, `projectLabelAsleepVersusOffline`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests, then the whole suite, then regenerate specs.** Expected: PASS.
- [ ] **Step 5: Commit.**

## Phase 4: Mobile

### Task 14: Measure the cost of connecting to every host (user gate)

The approved design says to measure this and bring the result to the user before building the rest of mobile.

- [ ] **Step 1: Measure what's possible here:** connection count and panes-feed bytes per minute per host, and time to first rows, using the isolated dev instance. Say clearly what can't be measured without a real device, such as battery.
- [ ] **Step 2: Report to the user and wait.** Tasks 15 to 18 start after that.

### Task 15: Multi-host feed and selection

**Files:**
- Create: `Sources/GrafttyMobileKit/App/MultiHostFeed.swift`
- Modify: `IPadAppState.swift`, `IPadWorktreeFeed.swift`, `RootView.swift`, `IPadRootLayout.swift`
- Test: `Tests/GrafttyMobileKitTests/`

**Interfaces:**
- Consumes: `ProjectMerge`, `MergedWorktreeList`, `HostSnapshotCache`, quiet `connection(for:)`.
- Produces: `MultiHostFeed` with `rows`, `projects`, and `availability(of:)`; `WorktreeSelection { hostID: UUID, path: String }`.

- [ ] **Steps:** failing tests (`connectsAllPairedHostsQuietly`, `showsCachedRowsBeforeConnecting`, `selectionIsHostPlusPath`, `changingSelectedHostDoesNotStopOtherPanes`, `samePathOnTwoHostsDistinct`), run, implement, run, simulator compile, commit.

### Task 16: Projects root and Hosts screen

**Files:**
- Modify: `RootView.swift`, `IPadRootLayout.swift`, `WorktreeListContent.swift`, `Hosts/HostPickerView.swift`
- Test: `Tests/GrafttyMobileKitTests/`

Projects → Worktree → Terminal becomes the iPhone path. The iPad host menu goes away. `HostPickerView` becomes the Hosts screen behind a gear, and it doesn't change what the app shows.

- [ ] **Steps:** failing tests (`compactRootIsProjects`, `hostsScreenDoesNotChangeSelection`, `projectListShowsAsleepAndOffline`, `pairingFlowStillReachable`), run, implement, run, simulator compile, commit.

### Task 17: Mobile rows, host label and Add Worktree

**Files:**
- Modify: `WorktreeBlock.swift`, `MobileWorktreeOverviewView.swift`, `IPadWorktreeIdentityBar.swift`, `MobileWorktreeContextDrawer.swift`, `AddWorktreeSheetView.swift`, `WorktreePickerGrouping.swift`
- Test: `Tests/GrafttyMobileKitTests/`

Rows use `SidebarRowStatus`. The host leads the iPad subtitle, joins the iPhone project caption, and heads the context drawer. Add Worktree goes project first, then host, using `AddWorktreeHostChoice`. Update `REMOTE-13.10`.

- [ ] **Steps:** failing tests (`rowShowsOneStatusLine`, `ipadSubtitleLeadsWithHost`, `iphoneCaptionIncludesHost`, `addSheetProjectThenHost`), run, implement, run, simulator compile, commit.

### Task 18: Mobile waking and drags

**Files:**
- Modify: `WorktreeListContent.swift`, `RootView.swift`, `SingleSessionView.swift`, `IPadRootLayout.swift`
- Test: `Tests/GrafttyMobileKitTests/`

Opening a sleeping worktree, tapping its question or dragging its pin wakes the host. Restoring doesn't. Pin and project drags use ranks, and relayed hosts get de-duplicated.

- [ ] **Steps:** failing tests (`openingSleepingWorktreeWakes`, `foregroundDoesNotWake`, `restoredSelectionShowsWake`, `pinDragUsesRank`, `relayDeduplicated`), run, implement, run, simulator compile, commit.

## Phase 5: Finish

### Task 19: Whole-branch check

- [ ] **Step 1:** `scripts/swiftpm test`, the iOS simulator compile, `scripts/generate-specs.py --check`, and `scripts/check-linux-test-allowlist.py`. Expected: all pass.
- [ ] **Step 2:** Dispatch one fresh reviewer on the most capable model for the whole branch, and fix what it confirms.
- [ ] **Step 3:** Report to the user. Run `/code-review xhigh --fix` before any PR.
