import AppKit
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
import GrafttyRemoteClient

/// The remote-host operations the viewer needs. `RemoteMacsModel` is the
/// production conformer; tests drive the mutation queue with a fake.
@MainActor
protocol RemoteWorktreeViewerModel: AnyObject {
    var savedRemoteMacs: [RemoteMac] { get }
    var worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]] { get }
    func queuePaneControl(on remoteMac: RemoteMac, request: PaneControlRequest) -> Task<PaneControlResponse, Never>
    func connectViewer(to remoteMac: RemoteMac) async throws
    func openViewerTerminalSession(identity: RemoteMacIdentity, sessionName: String) async throws
        -> any WebSocketClient & Sendable
    func openWorktree(on remoteMac: RemoteMac, worktreePath: String) async -> WorktreeManagementResponse
    func acknowledgeViewedAttention(on remoteMac: RemoteMac, worktreePath: String, paneSessionName: String?) async
    func sendWorktreeManagement(identity: RemoteMacIdentity, request: WorktreeManagementRequest) async throws
        -> WorktreeManagementResponse
}

/// The terminal-surface operations the viewer needs. `TerminalManager` is
/// the production conformer.
@MainActor
protocol RemoteWorktreeViewerSurfaces: AnyObject {
    var splitPreserveZoomOnNavigation: Bool { get }
    func hasRemoteSurface(_ terminalID: PaneSlotID) -> Bool
    /// Creates the host-managed surface that proxies `client`. Returns false
    /// when no surface could be created.
    func createRemoteSurface(
        terminalID: PaneSlotID,
        worktreePath: String,
        client: any WebSocketClient & Sendable,
        onUnexpectedClose: @escaping () -> Void,
        agentCompletions: @escaping () async throws -> [AgentCompletionCandidate]
    ) -> Bool
    func destroySurface(terminalID: PaneSlotID)
    func setVisible(_ visible: Bool, for terminalID: PaneSlotID)
    func setFocus(_ terminalID: PaneSlotID)
    func registerHostManagedPaneCommandHandler(
        for terminalID: PaneSlotID,
        handler: @escaping (HostManagedPaneCommand) -> Void
    )
    func promoteToFirstResponder(
        _ terminalID: PaneSlotID,
        when shouldFocus: (() -> Bool)?,
        onFocused: (() -> Void)?
    )
}

@MainActor
final class RemoteWorktreeViewerController: ObservableObject {
    struct WorktreeKey: Hashable {
        var identity: RemoteMacIdentity
        var worktreePath: String
    }

    // What the window draws. The queue reassigns these on every
    // synchronize pass, usually to the same value, so each setter
    // publishes only a real change (REMOTE-24.13).
    private(set) var selectedRemoteIdentity: RemoteMacIdentity? {
        get { state.selectedRemoteIdentity }
        set { publish(\.selectedRemoteIdentity, newValue) }
    }
    private(set) var selectedRemoteWorktreePath: String? {
        get { state.selectedRemoteWorktreePath }
        set { publish(\.selectedRemoteWorktreePath, newValue) }
    }
    private(set) var selectedRemotePaneSessionName: String? {
        get { state.selectedRemotePaneSessionName }
        set { publish(\.selectedRemotePaneSessionName, newValue) }
    }
    var splitTree: SplitTree {
        get { state.splitTree }
        set { publish(\.splitTree, newValue) }
    }
    private(set) var openingRemoteWorktrees: Set<WorktreeKey> {
        get { state.openingRemoteWorktrees }
        set { publish(\.openingRemoteWorktrees, newValue) }
    }

    private struct ViewState {
        var selectedRemoteIdentity: RemoteMacIdentity?
        var selectedRemoteWorktreePath: String?
        var selectedRemotePaneSessionName: String?
        var splitTree = SplitTree(root: nil)
        var openingRemoteWorktrees: Set<WorktreeKey> = []
    }

    private var state = ViewState()

    private func publish<Value: Equatable>(_ field: WritableKeyPath<ViewState, Value>, _ value: Value) {
        guard state[keyPath: field] != value else { return }
        objectWillChange.send()
        state[keyPath: field] = value
    }

    private let model: RemoteWorktreeViewerModel
    private let surfaces: RemoteWorktreeViewerSurfaces
    private let presentError: @MainActor (String) -> Void
    private let viewportBounds: @MainActor () -> CGRect?
    private let sleep: @MainActor (Duration) async -> Void

    init(
        model: RemoteWorktreeViewerModel,
        surfaces: RemoteWorktreeViewerSurfaces,
        presentError: @escaping @MainActor (String) -> Void = RemoteWorktreeViewerController.presentAlert,
        viewportBounds: @escaping @MainActor () -> CGRect? = { NSApp.keyWindow?.contentView?.bounds },
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.model = model
        self.surfaces = surfaces
        self.presentError = presentError
        self.viewportBounds = viewportBounds
        self.sleep = sleep
    }

    private static func presentAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Remote worktree operation failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // Queue and surface bookkeeping. None of it is read by a view, so it is
    // not published: changing it does not re-evaluate the window body.
    private var remoteTerminalSlots: [RemoteTerminalKey: PaneSlotID] = [:]
    private var openingRemoteTerminals: [RemoteTerminalKey: PaneSlotID] = [:]
    private var scheduledRemoteTerminalRetries: Set<RemoteTerminalKey> = []
    private var appIsVisible = true
    private var pendingRemoteFocusTarget: WorktreeKey?
    private var pendingRemoteSplitFocus: [PendingRemoteSplitFocus] = []
    private var pendingRemoteSplitFocusResults: [PendingRemoteSplitFocusResult] = []
    private var pendingRemoteCloseProjections: [WorktreeKey: PendingRemoteCloseProjection] = [:]
    private var pendingRemotePaneControls: [PendingRemotePaneControl] = []
    private var pendingRemoteMutationOrder: [UUID] = []
    private var remoteMutationInFlight: UUID?
    private var remotePaneIntentGeneration: UInt64 = 0

    var selectedRemoteMac: RemoteMac? {
        guard let selectedRemoteIdentity else { return nil }
        return model.savedRemoteMacs.first {
            RemoteMacIdentity($0) == selectedRemoteIdentity
        }
    }

    var selectedWorktreeSnapshot: WorktreePanes? {
        guard let identity = selectedRemoteIdentity,
              let path = selectedRemoteWorktreePath else { return nil }
        return model.worktreePanesByRemote[identity]?.first {
            $0.path == path && ($0.origin?.relayDepth ?? 0) == 0
        }
    }

    var isOpeningSelectedWorktree: Bool {
        guard let identity = selectedRemoteIdentity,
              let worktreePath = selectedRemoteWorktreePath else { return false }
        return openingRemoteWorktrees.contains(
            WorktreeKey(identity: identity, worktreePath: worktreePath)
        )
    }

    // MARK: - Selection intents

    func selectRemoteMac(_ remoteMac: RemoteMac) {
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        setRemoteSurfacesVisible(false)
        var selection = currentSelection
        RemoteMacSidebarSelectionReducer.selectRemote(RemoteMacIdentity(remoteMac), state: &selection)
        pendingRemoteFocusTarget = nil
        suppressPendingRemoteSplitFocus()
        apply(selection)
        splitTree = SplitTree(root: nil)
        if let previousIdentity, let previousWorktreePath {
            destroyRemoteSurfaces(
                identity: previousIdentity,
                worktreePath: previousWorktreePath
            )
        }
    }

    /// In-flight rows (creating, deleting) cannot be selected.
    func canSelectRemoteWorktree(_ remoteMac: RemoteMac, worktreePath: String) -> Bool {
        model.worktreePanesByRemote[RemoteMacIdentity(remoteMac)]?.first(where: {
            $0.path == worktreePath && ($0.origin?.relayDepth ?? 0) == 0
        })?.state.isInFlight != true
    }

    func selectRemoteWorktree(_ remoteMac: RemoteMac, worktreePath: String, acknowledging: Bool) {
        guard canSelectRemoteWorktree(remoteMac, worktreePath: worktreePath) else { return }
        let identity = RemoteMacIdentity(remoteMac)
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        setRemoteSurfacesVisible(false)
        var selection = currentSelection
        let target = WorktreeKey(
            identity: identity,
            worktreePath: worktreePath
        )
        suppressPendingRemoteSplitFocus()
        RemoteMacSidebarSelectionReducer.selectRemoteWorktree(
            identity,
            worktreePath: worktreePath,
            state: &selection
        )
        apply(selection)
        pendingRemoteFocusTarget = target
        if let previousIdentity,
           let previousWorktreePath,
           previousIdentity != identity
            || previousWorktreePath != worktreePath {
            destroyRemoteSurfaces(
                identity: previousIdentity,
                worktreePath: previousWorktreePath
            )
        }
        synchronizeRemoteWorktree(remoteMac: remoteMac, worktreePath: worktreePath)
        if selectedWorktreeSnapshot?.state == .closed,
           !openingRemoteWorktrees.contains(target) {
            openingRemoteWorktrees.insert(target)
            Task { @MainActor in
                let response = await model.openWorktree(
                    on: remoteMac,
                    worktreePath: worktreePath
                )
                if case let .error(_, message, _, _) = response {
                    openingRemoteWorktrees.remove(target)
                    if pendingRemoteFocusTarget == target {
                        pendingRemoteFocusTarget = nil
                    }
                    presentError(message)
                } else if response != .ok {
                    openingRemoteWorktrees.remove(target)
                    presentError(
                        "The remote Mac returned an unexpected response."
                    )
                }
            }
        }
        if acknowledging { Task {
            await model.acknowledgeViewedAttention(
                on: remoteMac,
                worktreePath: worktreePath,
                paneSessionName: nil
            )
        } }
    }

    func selectRemotePane(_ remoteMac: RemoteMac, worktreePath: String, sessionName: String, acknowledging: Bool) {
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        setRemoteSurfacesVisible(false)
        var selection = currentSelection
        let identity = RemoteMacIdentity(remoteMac)
        let target = WorktreeKey(
            identity: identity,
            worktreePath: worktreePath
        )
        suppressPendingRemoteSplitFocus()
        RemoteMacSidebarSelectionReducer.selectRemotePane(
            identity,
            worktreePath: worktreePath,
            sessionName: sessionName,
            state: &selection
        )
        apply(selection)
        pendingRemoteFocusTarget = target
        if let previousIdentity,
           let previousWorktreePath,
           previousIdentity != identity
            || previousWorktreePath != worktreePath {
            destroyRemoteSurfaces(
                identity: previousIdentity,
                worktreePath: previousWorktreePath
            )
        }

        synchronizeRemoteWorktree(
            remoteMac: remoteMac,
            worktreePath: worktreePath,
            preferredSessionName: sessionName
        )
        if acknowledging { Task {
            await model.acknowledgeViewedAttention(
                on: remoteMac,
                worktreePath: worktreePath,
                paneSessionName: sessionName
            )
        } }
    }

    /// The user picked a local worktree: drop the remote selection and every
    /// remote surface.
    func leaveForLocalSelection() {
        pendingRemoteFocusTarget = nil
        suppressPendingRemoteSplitFocus()
        setRemoteSurfacesVisible(false)
        destroyAllRemoteSurfaces()
        apply(RemoteMacSidebarSelectionState())
    }

    /// Runs whenever `worktreePanesByRemote` publishes a new snapshot.
    func reconcile(worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]]) {
        reconcileRemoteSelection(worktreePanesByRemote: worktreePanesByRemote)
    }

    /// A click (or other explicit focus) on a projected remote pane.
    func focusTerminal(_ terminalID: PaneSlotID) {
        suppressPendingRemoteSplitFocus()
        if let sessionName = remoteSessionName(for: terminalID) {
            selectedRemotePaneSessionName = sessionName
            if let selectedRemoteMac,
               let worktreePath = selectedRemoteWorktreePath {
                Task {
                    await model.acknowledgeViewedAttention(
                        on: selectedRemoteMac,
                        worktreePath: worktreePath,
                        paneSessionName: sessionName
                    )
                }
            }
        }
        guard let identity = selectedRemoteIdentity,
              let worktreePath = selectedRemoteWorktreePath else { return }
        focusRemotePane(
            terminalID,
            target: WorktreeKey(identity: identity, worktreePath: worktreePath)
        )
    }

    /// Records app hide/unhide. Returns true when a remote worktree is
    /// selected, in which case the remote surfaces have been updated and the
    /// caller has no local surfaces to change.
    @discardableResult
    func setAppVisible(_ isVisible: Bool) -> Bool {
        appIsVisible = isVisible
        guard selectedRemoteWorktreePath != nil else { return false }
        setRemoteSurfacesVisible(isVisible)
        if isVisible,
           let remoteMac = selectedRemoteMac,
           let worktreePath = selectedRemoteWorktreePath {
            synchronizeRemoteWorktree(
                remoteMac: remoteMac,
                worktreePath: worktreePath,
                focusSelection: false
            )
        }
        return true
    }

    private var currentSelection: RemoteMacSidebarSelectionState {
        RemoteMacSidebarSelectionState(
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
    }

    /// The local half of the selection belongs to `AppState`; only the
    /// remote half is applied here.
    private func apply(_ selection: RemoteMacSidebarSelectionState) {
        selectedRemoteIdentity = selection.selectedRemoteIdentity
        selectedRemoteWorktreePath = selection.selectedRemoteWorktreePath
        selectedRemotePaneSessionName = selection.selectedRemotePaneSessionName
    }

    // MARK: - Moved from MainWindow

    private struct RemoteTerminalKey: Hashable {
        var identity: RemoteMacIdentity
        var worktreePath: String
        var sessionName: String
    }

    private struct PendingRemoteSplitFocus {
        var id: UUID
        var target: WorktreeKey
        var sourceSessionName: String
        var direction: PaneControlRequest.SplitDirection
        var existingSessionNames: Set<String>
        var existingSessionOrder: [String]
        var previousZoomedSessionName: String?
        var focusGeneration: UInt64
        var isDispatched = false
        var shouldFocus = true
        var legacySucceeded = false
    }

    private struct PendingRemoteSplitFocusResult {
        var target: WorktreeKey
        var existingSessionNames: Set<String>
        var expectedSessionName: String?
        var focusGeneration: UInt64
        var projectedSessionOrder: [String]
        var removedSessionName: String?
    }

    private struct PendingRemoteCloseProjection {
        var removedSessionNames: Set<String>
        var projectedSessionOrder: [String]
    }

    private struct PendingRemotePaneControl {
        let id: UUID
        var request: PaneControlRequest
        let remoteMac: RemoteMac
        let target: WorktreeKey
        let restoreSnapshotOnError: Bool
        let clearViewerZoomOnSuccess: Bool
        var restoreViewerZoomOnError: String?
        var closeProjection: PaneCloseProjection?
        let focusGeneration: UInt64
    }

    private func reconcileRemoteSelection(
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]]
    ) {
        reconcileRemoteCloseProjections(
            worktreePanesByRemote: worktreePanesByRemote
        )
        resolveLegacyRemoteSplits(
            worktreePanesByRemote: worktreePanesByRemote
        )
        openingRemoteWorktrees = openingRemoteWorktrees.filter { target in
            worktreePanesByRemote[target.identity]?.contains {
                $0.path == target.worktreePath
                    && ($0.origin?.relayDepth ?? 0) == 0
                    && $0.state == .closed
            } == true
        }
        let currentIdentities = Set(worktreePanesByRemote.keys)
        let staleIdentities = Set(remoteTerminalSlots.keys.map(\.identity))
            .subtracting(currentIdentities)
        for identity in staleIdentities {
            destroyRemoteSurfaces(identity: identity)
        }
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        let previousPaneSessionName = selectedRemotePaneSessionName
        var selection = currentSelection
        RemoteMacSidebarSelectionReducer.reconcileRemoteSelection(
            worktreePanesByRemote: worktreePanesByRemote,
            state: &selection
        )
        apply(selection)

        if selection.selectedRemoteWorktreePath == nil {
            pendingRemoteFocusTarget = nil
            suppressPendingRemoteSplitFocus()
            if let previousIdentity, let previousWorktreePath {
                destroyRemoteSurfaces(
                    identity: previousIdentity,
                    worktreePath: previousWorktreePath
                )
            }
            splitTree = SplitTree(root: nil)
        } else if let remoteMac = selectedRemoteMac,
                  let worktreePath = selection.selectedRemoteWorktreePath {
            let shouldFocusReplacement = previousIdentity
                == selection.selectedRemoteIdentity
                && previousWorktreePath == worktreePath
                && previousPaneSessionName != nil
                && selection.selectedRemotePaneSessionName == nil
            let target = WorktreeKey(
                identity: RemoteMacIdentity(remoteMac),
                worktreePath: worktreePath
            )
            if shouldFocusReplacement {
                pendingRemoteFocusTarget = target
            }
            synchronizeRemoteWorktree(
                remoteMac: remoteMac,
                worktreePath: worktreePath,
                preferredSessionName: selection.selectedRemotePaneSessionName,
                focusSelection: false
            )
        }
    }

    private func reconcileRemoteCloseProjections(
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]]
    ) {
        let savedIdentities = Set(
            model.savedRemoteMacs.map(RemoteMacIdentity.init)
        )
        for target in Array(pendingRemoteCloseProjections.keys) {
            guard savedIdentities.contains(target.identity) else {
                pendingRemoteCloseProjections[target] = nil
                continue
            }
            guard let worktrees = worktreePanesByRemote[target.identity] else {
                // An offline saved Mac has no authoritative snapshot yet.
                continue
            }
            let sessionNames = Set(
                worktrees.first(where: {
                    $0.path == target.worktreePath
                        && ($0.origin?.relayDepth ?? 0) == 0
                })?.layout?.leaves.map(\.sessionName) ?? []
            )
            if pendingRemoteCloseProjections[target]?
                .removedSessionNames.isDisjoint(with: sessionNames) == true {
                pendingRemoteCloseProjections[target] = nil
            }
        }
    }

    private func synchronizeRemoteWorktree(
        remoteMac: RemoteMac,
        worktreePath: String,
        preferredSessionName: String? = nil,
        focusSelection: Bool = true
    ) {
        let identity = RemoteMacIdentity(remoteMac)
        let focusTarget = WorktreeKey(
            identity: identity,
            worktreePath: worktreePath
        )
        guard let worktree = model.worktreePanesByRemote[identity]?
            .first(where: {
                $0.path == worktreePath && ($0.origin?.relayDepth ?? 0) == 0
            }) else {
            pendingRemoteSplitFocusResults.removeAll {
                $0.target == focusTarget && $0.removedSessionName != nil
            }
            pendingRemoteCloseProjections[focusTarget] = nil
            if selectedRemoteIdentity == identity,
               selectedRemoteWorktreePath == worktreePath {
                selectedRemotePaneSessionName = nil
            }
            destroyRemoteSurfaces(identity: identity, worktreePath: worktreePath)
            splitTree = SplitTree(root: nil)
            return
        }
        guard let layout = worktree.layout else {
            pendingRemoteSplitFocusResults.removeAll {
                $0.target == focusTarget && $0.removedSessionName != nil
            }
            pendingRemoteCloseProjections[focusTarget] = nil
            if selectedRemoteIdentity == identity,
               selectedRemoteWorktreePath == worktreePath {
                selectedRemotePaneSessionName = nil
            }
            destroyRemoteSurfaces(identity: identity, worktreePath: worktreePath)
            splitTree = SplitTree(root: nil)
            return
        }

        let sessionNames = Set(layout.leaves.map(\.sessionName))
        if let closeProjection = pendingRemoteCloseProjections[focusTarget],
           closeProjection.removedSessionNames.isDisjoint(
               with: sessionNames
           ) {
            // Every confirmed removal is now authoritative. Focus results
            // can reconcile below; the topology tombstone has done its job.
            pendingRemoteCloseProjections[focusTarget] = nil
        }
        let removedSessionNames =
            pendingRemoteCloseProjections[focusTarget]?
            .removedSessionNames.intersection(sessionNames) ?? []
        let visibleSessionNames =
            sessionNames.subtracting(removedSessionNames)
        let staleKeys = remoteTerminalSlots.keys.filter {
            $0.identity == identity
                && $0.worktreePath == worktreePath
                && !visibleSessionNames.contains($0.sessionName)
        }
        for key in staleKeys {
            if let terminalID = remoteTerminalSlots.removeValue(forKey: key) {
                surfaces.destroySurface(terminalID: terminalID)
            }
        }

        let zoomedSessionName = splitTree.zoomed.flatMap {
            remoteSessionName(for: $0)
        }
        var projectedTree = SplitTree(
            root: RemotePaneLayoutProjection.node(from: layout) {
                remoteTerminalSlot(
                    identity: identity,
                    worktreePath: worktreePath,
                    sessionName: $0
                )
            }
        )
        for removedSessionName in removedSessionNames {
            let removedKey = RemoteTerminalKey(
                identity: identity,
                worktreePath: worktreePath,
                sessionName: removedSessionName
            )
            if let removedID = remoteTerminalSlots.removeValue(
                forKey: removedKey
            ) {
                projectedTree = projectedTree.removing(removedID)
                surfaces.destroySurface(terminalID: removedID)
            }
        }
        if let zoomedSessionName,
           visibleSessionNames.contains(zoomedSessionName),
           let zoomedID = remoteTerminalSlots[RemoteTerminalKey(
            identity: identity,
            worktreePath: worktreePath,
            sessionName: zoomedSessionName
           )] {
            projectedTree = projectedTree.withZoom(zoomedID)
        }
        splitTree = projectedTree
        var newestSplitSessionName: String?
        while let pendingIndex = pendingRemoteSplitFocusResults.firstIndex(
            where: { $0.target == focusTarget }
        ) {
            let pending = pendingRemoteSplitFocusResults[pendingIndex]
            if let removedSessionName = pending.removedSessionName {
                guard !sessionNames.contains(removedSessionName) else {
                    break
                }
                pendingRemoteSplitFocusResults.remove(at: pendingIndex)
                newestSplitSessionName =
                    pending.expectedSessionName.flatMap {
                        visibleSessionNames.contains($0) ? $0 : nil
                    }
                    ?? layout.leaves.lazy.map(\.sessionName).first {
                        visibleSessionNames.contains($0)
                    }
                continue
            }
            let newSessionName: String?
            if let expectedSessionName = pending.expectedSessionName {
                newSessionName = sessionNames.contains(expectedSessionName)
                    ? expectedSessionName
                    : nil
            } else {
                // Compatibility fallback for older hosts that only return
                // `.ok`. Current hosts return the exact created session.
                newSessionName = layout.leaves.lazy.map(\.sessionName)
                    .first(where: {
                        !pending.existingSessionNames.contains($0)
                    })
            }
            guard let newSessionName else { break }
            pendingRemoteSplitFocusResults.remove(at: pendingIndex)
            for index in pendingRemoteSplitFocusResults.indices
            where pendingRemoteSplitFocusResults[index].target == focusTarget {
                pendingRemoteSplitFocusResults[index]
                    .existingSessionNames.insert(
                        newSessionName
                    )
            }
            newestSplitSessionName = newSessionName
        }
        if let newestSplitSessionName {
            selectedRemotePaneSessionName = newestSplitSessionName
            pendingRemoteFocusTarget = focusTarget
        }
        let focusedSession = preferredSessionName.flatMap {
            visibleSessionNames.contains($0) ? $0 : nil
        } ?? selectedRemotePaneSessionName.flatMap {
            visibleSessionNames.contains($0) ? $0 : nil
        } ?? layout.leaves.lazy.map(\.sessionName).first {
            visibleSessionNames.contains($0)
        }
        selectedRemotePaneSessionName = focusedSession

        for leaf in layout.leaves
        where visibleSessionNames.contains(leaf.sessionName) {
            let key = RemoteTerminalKey(
                identity: identity,
                worktreePath: worktreePath,
                sessionName: leaf.sessionName
            )
            guard let terminalID = remoteTerminalSlots[key],
                  !surfaces.hasRemoteSurface(terminalID),
                  openingRemoteTerminals[key] == nil else {
                continue
            }
            openingRemoteTerminals[key] = terminalID
            Task { @MainActor in
                defer {
                    if openingRemoteTerminals[key] == terminalID {
                        openingRemoteTerminals[key] = nil
                    }
                }
                do {
                    try await model.connectViewer(to: remoteMac)
                    let client = try await model.openViewerTerminalSession(
                        identity: identity,
                        sessionName: leaf.sessionName
                    )
                    guard remoteTerminalSlots[key] == terminalID else {
                        client.close()
                        return
                    }
                    guard surfaces.createRemoteSurface(
                        terminalID: terminalID,
                        worktreePath: worktreePath,
                        client: client,
                        onUnexpectedClose: { [weak controller = self] in
                            Task { @MainActor in
                                controller?.handleRemoteSurfaceClosed(
                                    source: key,
                                    terminalID: terminalID
                                )
                            }
                        },
                        agentCompletions: { [model] in
                            let response = try await model.sendWorktreeManagement(identity: identity,
                                request: .worktreeAgentCompletions(worktreeID: worktreePath))
                            guard case .agentCompletions(let candidates) = response else {
                                throw RemoteWorktreeError("Agent completion is unavailable on this host")
                            }
                            return candidates
                        }
                    ) else {
                        scheduleRemoteTerminalRetry(
                            source: key,
                            remoteMac: remoteMac
                        )
                        return
                    }
                    let isSelected = selectedRemoteIdentity == identity
                        && selectedRemoteWorktreePath == worktreePath
                    surfaces.setVisible(
                        isSelected && appIsVisible,
                        for: terminalID
                    )
                    let shouldFocus = focusSelection
                        || pendingRemoteFocusTarget == focusTarget
                    if isSelected
                        && appIsVisible
                        && shouldFocus
                        && selectedRemotePaneSessionName == leaf.sessionName {
                        focusRemotePane(terminalID, target: focusTarget)
                    }
                } catch {
                    NSLog(
                        "[Graftty] failed to open remote terminal %@ on %@: %@",
                        leaf.sessionName,
                        remoteMac.label,
                        String(describing: error)
                    )
                    scheduleRemoteTerminalRetry(
                        source: key,
                        remoteMac: remoteMac
                    )
                }
            }
        }
        setRemoteSurfacesVisible(appIsVisible)
        let shouldFocus = focusSelection
            || pendingRemoteFocusTarget == focusTarget
        if appIsVisible,
           shouldFocus,
           let focusedTerminalID,
           surfaces.hasRemoteSurface(focusedTerminalID) {
            focusRemotePane(
                focusedTerminalID,
                target: focusTarget
            )
        }
    }

    private func remoteTerminalSlot(
        identity: RemoteMacIdentity,
        worktreePath: String,
        sessionName: String
    ) -> PaneSlotID {
        let key = RemoteTerminalKey(
            identity: identity,
            worktreePath: worktreePath,
            sessionName: sessionName
        )
        if let existing = remoteTerminalSlots[key] {
            return existing
        }
        let terminalID = PaneSlotID()
        remoteTerminalSlots[key] = terminalID
        surfaces.registerHostManagedPaneCommandHandler(
            for: terminalID
        ) { [weak self] in
            self?.handleRemotePaneCommand(
                $0,
                source: key,
                sourceTerminalID: terminalID
            )
        }
        return terminalID
    }

    var focusedTerminalID: PaneSlotID? {
        guard let identity = selectedRemoteIdentity,
              let worktreePath = selectedRemoteWorktreePath,
              let sessionName = selectedRemotePaneSessionName else {
            return splitTree.allLeaves.first
        }
        return remoteTerminalSlots[RemoteTerminalKey(
            identity: identity,
            worktreePath: worktreePath,
            sessionName: sessionName
        )] ?? splitTree.allLeaves.first
    }

    private func remoteSessionName(for terminalID: PaneSlotID) -> String? {
        remoteTerminalSlots.first(where: { $0.value == terminalID })?.key.sessionName
    }

    private func handleRemotePaneCommand(
        _ command: HostManagedPaneCommand,
        source: RemoteTerminalKey,
        sourceTerminalID: PaneSlotID
    ) {
        guard remoteTerminalSlots[source] == sourceTerminalID else {
            if case .surfaceClosed = command {
                surfaces.destroySurface(
                    terminalID: sourceTerminalID
                )
            }
            return
        }
        if case .surfaceClosed = command {
            handleRemoteSurfaceClosed(
                source: source,
                terminalID: sourceTerminalID
            )
            return
        }
        guard selectedRemoteIdentity == source.identity,
              selectedRemoteWorktreePath == source.worktreePath,
              let remoteMac = selectedRemoteMac else { return }
        let target = WorktreeKey(
            identity: source.identity,
            worktreePath: source.worktreePath
        )
        let inheritedFocusResults = pendingRemoteSplitFocusResults.filter {
            $0.target == target
                && $0.focusGeneration == remotePaneIntentGeneration
        }
        let closeProjection = pendingRemoteCloseProjections[target]
        if closeProjection?.projectedSessionOrder.isEmpty == true {
            // The final pane has closed successfully, but polling has not
            // yet published the empty layout. Ignore commands emitted by
            // the stale surface during that response-to-snapshot gap.
            return
        }
        let effectiveSessionName =
            inheritedFocusResults.last?.expectedSessionName
            ?? closeProjection.flatMap {
                $0.projectedSessionOrder.contains(source.sessionName)
                    ? source.sessionName
                    : $0.projectedSessionOrder.first
            }
            ?? source.sessionName
        let projectedSessionOrder =
            inheritedFocusResults.last?.projectedSessionOrder
            ?? closeProjection?.projectedSessionOrder
            ?? splitTree.allLeaves.compactMap {
                remoteSessionName(for: $0)
            }
        let projectedSessionNames = Set(projectedSessionOrder)

        switch command {
        case .split(let split):
            let direction: PaneControlRequest.SplitDirection
            switch split {
            case .right:
                direction = .right
            case .down:
                direction = .down
            case .left:
                direction = .left
            case .up:
                direction = .up
            }
            let pending = PendingRemoteSplitFocus(
                id: UUID(),
                target: target,
                sourceSessionName: effectiveSessionName,
                direction: direction,
                existingSessionNames: projectedSessionNames,
                existingSessionOrder: projectedSessionOrder,
                previousZoomedSessionName: nil,
                focusGeneration: remotePaneIntentGeneration
            )
            pendingRemoteSplitFocus.append(pending)
            pendingRemoteMutationOrder.append(pending.id)
            dispatchNextRemoteMutation()

        case .close:
            sendRemotePaneControl(
                .close(target: effectiveSessionName),
                on: remoteMac,
                target: target,
                projectedSessionOrder: projectedSessionOrder
            )

        case .surfaceClosed:
            return

        case .focus(let direction):
            guard let sourceID = remoteTerminalSlots[source],
                  let nextID = splitTree.spatialNeighbor(
                    of: sourceID,
                    direction: direction.asSpatial
                  ),
                  let sessionName = remoteSessionName(for: nextID) else {
                return
            }
            if splitTree.zoomed != nil {
                splitTree =
                    surfaces.splitPreserveZoomOnNavigation
                    ? splitTree.withZoom(nextID)
                    : splitTree.withZoom(nil)
            }
            selectRemotePaneSession(
                sessionName,
                terminalID: nextID,
                remoteMac: remoteMac,
                target: target
            )

        case .focusOrder(let forward):
            guard let sourceID = remoteTerminalSlots[source],
                  let currentIndex = splitTree.allLeaves
                    .firstIndex(of: sourceID),
                  splitTree.allLeaves.count > 1 else {
                return
            }
            let leaves = splitTree.allLeaves
            let nextIndex = forward
                ? (currentIndex + 1) % leaves.count
                : (currentIndex - 1 + leaves.count) % leaves.count
            let nextID = leaves[nextIndex]
            guard let sessionName = remoteSessionName(for: nextID) else {
                return
            }
            if splitTree.zoomed != nil {
                splitTree =
                    surfaces.splitPreserveZoomOnNavigation
                    ? splitTree.withZoom(nextID)
                    : splitTree.withZoom(nil)
            }
            selectRemotePaneSession(
                sessionName,
                terminalID: nextID,
                remoteMac: remoteMac,
                target: target
            )

        case .toggleZoom:
            guard let sourceID = remoteTerminalSlots[source] else { return }
            suppressPendingRemoteSplitFocus()
            splitTree = splitTree.togglingZoom(
                at: sourceID
            )

        case .equalize:
            sendRemotePaneControl(
                .equalize(target: effectiveSessionName),
                on: remoteMac,
                target: target,
                restoreSnapshotOnError: true,
                clearViewerZoomOnSuccess: true
            )

        case let .resize(direction, amount):
            let wireDirection: PaneControlRequest.SplitDirection
            switch direction {
            case .right:
                wireDirection = .right
            case .down:
                wireDirection = .down
            case .left:
                wireDirection = .left
            case .up:
                wireDirection = .up
            }
            let bounds = viewportBounds()
                ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let extent: CGFloat
            switch direction {
            case .left, .right:
                extent = bounds.width
            case .up, .down:
                extent = bounds.height
            }
            sendRemotePaneControl(
                .resize(
                    target: effectiveSessionName,
                    direction: wireDirection,
                    amount: amount,
                    viewportExtent: UInt32(
                        clamping: max(1, Int(extent.rounded()))
                    )
                ),
                on: remoteMac,
                target: target,
                restoreSnapshotOnError: true,
                clearViewerZoomOnSuccess: true
            )
        }
    }

    private func handleRemoteSurfaceClosed(
        source: RemoteTerminalKey,
        terminalID: PaneSlotID
    ) {
        guard remoteTerminalSlots[source] == terminalID else {
            surfaces.destroySurface(terminalID: terminalID)
            return
        }
        let shouldRestoreFocus = focusedTerminalID == terminalID
        openingRemoteTerminals[source] = nil
        remoteTerminalSlots[source] = nil
        surfaces.destroySurface(terminalID: terminalID)
        guard selectedRemoteIdentity == source.identity,
              selectedRemoteWorktreePath == source.worktreePath,
              let remoteMac = selectedRemoteMac else {
            splitTree =
                splitTree.removing(terminalID)
            return
        }
        if shouldRestoreFocus {
            pendingRemoteFocusTarget = WorktreeKey(
                identity: source.identity,
                worktreePath: source.worktreePath
            )
        }
        synchronizeRemoteWorktree(
            remoteMac: remoteMac,
            worktreePath: source.worktreePath,
            focusSelection: shouldRestoreFocus
        )
        scheduleRemoteTerminalRetry(source: source, remoteMac: remoteMac)
    }

    private func scheduleRemoteTerminalRetry(
        source: RemoteTerminalKey,
        remoteMac: RemoteMac
    ) {
        guard !scheduledRemoteTerminalRetries.contains(source) else { return }
        scheduledRemoteTerminalRetries.insert(source)
        Task { @MainActor in
            await sleep(.milliseconds(750))
            guard scheduledRemoteTerminalRetries.contains(source) else {
                return
            }
            scheduledRemoteTerminalRetries.remove(source)
            guard selectedRemoteIdentity == source.identity,
                  selectedRemoteWorktreePath == source.worktreePath,
                  model.worktreePanesByRemote[source.identity]?
                    .contains(where: {
                        $0.path == source.worktreePath
                            && $0.layout?.leaves.contains(where: {
                                $0.sessionName == source.sessionName
                            }) == true
                    }) == true,
                  let terminalID = remoteTerminalSlots[source],
                  !surfaces.hasRemoteSurface(terminalID) else {
                return
            }
            synchronizeRemoteWorktree(
                remoteMac: remoteMac,
                worktreePath: source.worktreePath,
                focusSelection: false
            )
        }
    }

    private func selectRemotePaneSession(
        _ sessionName: String,
        terminalID: PaneSlotID,
        remoteMac: RemoteMac,
        target: WorktreeKey
    ) {
        suppressPendingRemoteSplitFocus()
        selectedRemotePaneSessionName = sessionName
        pendingRemoteFocusTarget = target
        focusRemotePane(terminalID, target: target)
        Task {
            await model.acknowledgeViewedAttention(
                on: remoteMac,
                worktreePath: target.worktreePath,
                paneSessionName: sessionName
            )
        }
    }

    private func sendRemotePaneControl(
        _ request: PaneControlRequest,
        on remoteMac: RemoteMac,
        target: WorktreeKey,
        pendingSplitID: UUID? = nil,
        restoreSnapshotOnError: Bool = false,
        clearViewerZoomOnSuccess: Bool = false,
        restoreViewerZoomOnError: String? = nil,
        projectedSessionOrder: [String]? = nil,
        deferBehindPendingSplits: Bool = true,
        viewerEffectGeneration: UInt64? = nil,
        completion: (@MainActor (PaneControlResponse) -> Void)? = nil
    ) {
        if deferBehindPendingSplits,
           pendingSplitID == nil {
            let id = UUID()
            let closeProjection: PaneCloseProjection?
            if case .close(let closedSessionName) = request {
                closeProjection = PaneCloseProjection(
                    target: closedSessionName,
                    sessionOrder: projectedSessionOrder
                        ?? splitTree.allLeaves.compactMap {
                            remoteSessionName(for: $0)
                        }
                )
            } else {
                closeProjection = nil
            }
            pendingRemotePaneControls.append(PendingRemotePaneControl(
                id: id,
                request: request,
                remoteMac: remoteMac,
                target: target,
                restoreSnapshotOnError: restoreSnapshotOnError,
                clearViewerZoomOnSuccess: clearViewerZoomOnSuccess,
                restoreViewerZoomOnError: restoreViewerZoomOnError,
                closeProjection: closeProjection,
                focusGeneration: remotePaneIntentGeneration
            ))
            pendingRemoteMutationOrder.append(id)
            dispatchNextRemoteMutation()
            return
        }
        let operation = model.queuePaneControl(
            on: remoteMac,
            request: request
        )
        Task { @MainActor in
            let response = await operation.value
            defer { completion?(response) }
            switch response {
            case .splitCreated(let sessionName):
                if let pendingSplitID,
                   let index = pendingRemoteSplitFocus.firstIndex(
                    where: { $0.id == pendingSplitID }
                   ) {
                    let completed = pendingRemoteSplitFocus.remove(at: index)
                    pendingRemoteMutationOrder.removeAll {
                        $0 == completed.id
                    }
                    if remoteMutationInFlight == completed.id {
                        remoteMutationInFlight = nil
                    }
                    completeRemoteSplit(
                        completed,
                        createdSessionName: sessionName
                    )
                    if selectedRemoteIdentity == target.identity,
                       selectedRemoteWorktreePath == target.worktreePath {
                        synchronizeRemoteWorktree(
                            remoteMac: remoteMac,
                            worktreePath: target.worktreePath,
                            focusSelection: false
                        )
                    }
                    dispatchNextRemoteMutation()
                }
                return
            case .ok:
                if let pendingSplitID,
                   let index = pendingRemoteSplitFocus.firstIndex(
                    where: { $0.id == pendingSplitID }
                   ) {
                    // Released hosts return only `.ok`. Keep this mutation
                    // as the sole dispatched split until its next snapshot
                    // identifies the new leaf, preventing coalesced layouts
                    // from reversing rapid split focus.
                    pendingRemoteSplitFocus[index].legacySucceeded = true
                    scheduleLegacyRemoteSplitTimeout(
                        id: pendingSplitID,
                        target: target
                    )
                    resolveLegacyRemoteSplits(
                        worktreePanesByRemote:
                            model.worktreePanesByRemote
                    )
                    if selectedRemoteIdentity == target.identity,
                       selectedRemoteWorktreePath == target.worktreePath {
                        synchronizeRemoteWorktree(
                            remoteMac: remoteMac,
                            worktreePath: target.worktreePath,
                            focusSelection: false
                        )
                    }
                } else if clearViewerZoomOnSuccess,
                          viewerEffectGeneration
                            == remotePaneIntentGeneration,
                          selectedRemoteIdentity == target.identity,
                          selectedRemoteWorktreePath
                            == target.worktreePath {
                    splitTree =
                        splitTree.withZoom(nil)
                }
                return
            case .error(let code, let message):
                var failedPendingSplit: PendingRemoteSplitFocus?
                if let pendingSplitID,
                   let index = pendingRemoteSplitFocus.firstIndex(
                    where: { $0.id == pendingSplitID }
                   ) {
                    failedPendingSplit = pendingRemoteSplitFocus.remove(
                        at: index
                    )
                    pendingRemoteMutationOrder.removeAll {
                        $0 == pendingSplitID
                    }
                    if remoteMutationInFlight == pendingSplitID {
                        remoteMutationInFlight = nil
                    }
                }
                let abortsSplitBatch = code == "cancelled"
                    || code == "downstream-unavailable"
                var transferredRollback = false
                if !abortsSplitBatch,
                   let failedPendingSplit,
                   let rollbackZoom =
                    failedPendingSplit.previousZoomedSessionName,
                   let nextMutationID =
                    pendingRemoteMutationOrder.first,
                   let nextIndex = pendingRemoteSplitFocus.firstIndex(
                    where: {
                        $0.id == nextMutationID
                            && $0.target == failedPendingSplit.target
                            && $0.previousZoomedSessionName == nil
                    }
                   ) {
                    pendingRemoteSplitFocus[nextIndex]
                        .previousZoomedSessionName = rollbackZoom
                    transferredRollback = true
                }
                var rollbackCandidates = failedPendingSplit.map { [$0] } ?? []
                if abortsSplitBatch {
                    rollbackCandidates.append(contentsOf:
                        pendingRemoteSplitFocus.filter { $0.target == target }
                    )
                    let abandonedIDs = Set(
                        pendingRemoteSplitFocus
                            .filter { $0.target == target }
                            .map(\.id)
                        + pendingRemotePaneControls
                            .filter { $0.target == target }
                            .map(\.id)
                    )
                    pendingRemoteSplitFocus.removeAll { $0.target == target }
                    pendingRemoteSplitFocusResults.removeAll {
                        $0.target == target
                    }
                    pendingRemotePaneControls.removeAll {
                        $0.target == target
                    }
                    pendingRemoteMutationOrder.removeAll {
                        abandonedIDs.contains($0)
                    }
                    if let inFlight = remoteMutationInFlight,
                       abandonedIDs.contains(inFlight) {
                        remoteMutationInFlight = nil
                    }
                }
                if let rollback = rollbackCandidates.first(where: {
                    $0.shouldFocus && $0.previousZoomedSessionName != nil
                }),
                   let previousZoomedSessionName =
                    rollback.previousZoomedSessionName,
                   (abortsSplitBatch || !transferredRollback),
                   splitTree.zoomed == nil,
                   selectedRemoteIdentity == target.identity,
                   selectedRemoteWorktreePath == target.worktreePath,
                   let zoomedID = remoteTerminalSlots[RemoteTerminalKey(
                       identity: target.identity,
                       worktreePath: target.worktreePath,
                       sessionName: previousZoomedSessionName
                   )] {
                    splitTree =
                        splitTree.withZoom(zoomedID)
                }
                if restoreSnapshotOnError,
                   selectedRemoteIdentity == target.identity,
                   selectedRemoteWorktreePath == target.worktreePath {
                    synchronizeRemoteWorktree(
                        remoteMac: remoteMac,
                        worktreePath: target.worktreePath,
                        focusSelection: false
                    )
                    if viewerEffectGeneration
                        == remotePaneIntentGeneration,
                       let restoreViewerZoomOnError,
                       let zoomedID = remoteTerminalSlots[RemoteTerminalKey(
                        identity: target.identity,
                        worktreePath: target.worktreePath,
                        sessionName: restoreViewerZoomOnError
                       )] {
                        splitTree =
                            splitTree.withZoom(zoomedID)
                    }
                }
                if code != "no-matching-split" && code != "cancelled" {
                    presentError(message)
                }
                if failedPendingSplit != nil {
                    dispatchNextRemoteMutation()
                }
            }
        }
    }

    private func scheduleLegacyRemoteSplitTimeout(
        id: UUID,
        target: WorktreeKey
    ) {
        Task { @MainActor in
            await sleep(.seconds(10))
            guard remoteMutationInFlight == id,
                  pendingRemoteSplitFocus.contains(where: {
                      $0.id == id && $0.legacySucceeded
                  }) else {
                return
            }
            let abandonedIDs = Set(
                pendingRemoteSplitFocus
                    .filter { $0.target == target }
                    .map(\.id)
                + pendingRemotePaneControls
                    .filter { $0.target == target }
                    .map(\.id)
            )
            pendingRemoteSplitFocus.removeAll { $0.target == target }
            pendingRemoteSplitFocusResults.removeAll {
                $0.target == target
            }
            pendingRemotePaneControls.removeAll { $0.target == target }
            pendingRemoteMutationOrder.removeAll {
                abandonedIDs.contains($0)
            }
            remoteMutationInFlight = nil
            dispatchNextRemoteMutation()
        }
    }

    private func dispatchNextRemoteMutation() {
        guard remoteMutationInFlight == nil,
              let id = pendingRemoteMutationOrder.first else {
            return
        }
        if let index = pendingRemoteSplitFocus.firstIndex(where: {
            $0.id == id
        }) {
            pendingRemoteSplitFocus[index].isDispatched = true
            let ownsViewerState =
                pendingRemoteSplitFocus[index].shouldFocus
                && pendingRemoteSplitFocus[index].focusGeneration
                    == remotePaneIntentGeneration
                && selectedRemoteIdentity
                    == pendingRemoteSplitFocus[index].target.identity
                && selectedRemoteWorktreePath
                    == pendingRemoteSplitFocus[index].target.worktreePath
            if ownsViewerState {
                if pendingRemoteSplitFocus[index]
                    .previousZoomedSessionName == nil {
                    pendingRemoteSplitFocus[index]
                        .previousZoomedSessionName =
                        splitTree.zoomed.flatMap {
                            remoteSessionName(for: $0)
                        }
                }
                splitTree =
                    splitTree.withZoom(nil)
            }
            let pending = pendingRemoteSplitFocus[index]
            guard let remoteMac = model.savedRemoteMacs.first(
                where: {
                    RemoteMacIdentity($0) == pending.target.identity
                }
            ) else {
                pendingRemoteSplitFocus.remove(at: index)
                pendingRemoteMutationOrder.removeFirst()
                dispatchNextRemoteMutation()
                return
            }
            remoteMutationInFlight = id
            sendRemotePaneControl(
                .split(
                    target: pending.sourceSessionName,
                    direction: pending.direction
                ),
                on: remoteMac,
                target: pending.target,
                pendingSplitID: pending.id,
                deferBehindPendingSplits: false
            )
        } else if let index = pendingRemotePaneControls.firstIndex(where: {
            $0.id == id
        }) {
            var pending = pendingRemotePaneControls[index]
            let ownsViewerState =
                pending.focusGeneration == remotePaneIntentGeneration
                && selectedRemoteIdentity == pending.target.identity
                && selectedRemoteWorktreePath
                    == pending.target.worktreePath
            if case .equalize = pending.request, ownsViewerState {
                pending.restoreViewerZoomOnError =
                    splitTree.zoomed.flatMap {
                        remoteSessionName(for: $0)
                    }
                splitTree =
                    splitTree.equalizing()
                pendingRemotePaneControls[index] = pending
            }
            remoteMutationInFlight = id
            sendRemotePaneControl(
                pending.request,
                on: pending.remoteMac,
                target: pending.target,
                restoreSnapshotOnError: pending.restoreSnapshotOnError,
                clearViewerZoomOnSuccess:
                    pending.clearViewerZoomOnSuccess,
                restoreViewerZoomOnError:
                    pending.restoreViewerZoomOnError,
                deferBehindPendingSplits: false,
                viewerEffectGeneration: pending.focusGeneration
            ) { [self] response in
                completeRemotePaneControl(
                    pending,
                    response: response
                )
            }
        } else {
            pendingRemoteMutationOrder.removeFirst()
            dispatchNextRemoteMutation()
        }
    }

    private func completeRemoteSplit(
        _ completed: PendingRemoteSplitFocus,
        createdSessionName: String?
    ) {
        for index in pendingRemoteSplitFocus.indices
        where pendingRemoteSplitFocus[index].target == completed.target {
            // Any successful split commits the batch's local unzoom.
            pendingRemoteSplitFocus[index].previousZoomedSessionName = nil
            if let createdSessionName {
                pendingRemoteSplitFocus[index].existingSessionNames.insert(
                    createdSessionName
                )
                pendingRemoteSplitFocus[index].existingSessionOrder =
                    PaneCloseProjection.sessionOrder(
                        pendingRemoteSplitFocus[index].existingSessionOrder,
                        afterSplitting: completed.sourceSessionName,
                        created: createdSessionName,
                        direction: completed.direction
                    )
                // The exact created ID lets rapid commands follow local
                // focus-after-split semantics without waiting for polling.
                if pendingRemoteSplitFocus[index].focusGeneration
                    == completed.focusGeneration,
                   pendingRemoteSplitFocus[index].sourceSessionName
                    == completed.sourceSessionName {
                    pendingRemoteSplitFocus[index].sourceSessionName =
                        createdSessionName
                }
            }
        }
        if let createdSessionName {
            for index in pendingRemotePaneControls.indices
            where pendingRemotePaneControls[index].target
                == completed.target {
                if var projection =
                    pendingRemotePaneControls[index].closeProjection {
                    let inheritsFocus =
                        pendingRemotePaneControls[index].focusGeneration
                            == completed.focusGeneration
                    projection.projectSplit(
                        from: completed.sourceSessionName,
                        to: createdSessionName,
                        direction: completed.direction,
                        inheritsFocus: inheritsFocus
                    )
                    pendingRemotePaneControls[index].closeProjection =
                        projection
                    pendingRemotePaneControls[index].request = .close(
                        target: projection.target
                    )
                } else if pendingRemotePaneControls[index].focusGeneration
                    == completed.focusGeneration {
                    pendingRemotePaneControls[index].request =
                        pendingRemotePaneControls[index].request
                        .rebasingTarget(
                            from: completed.sourceSessionName,
                            to: createdSessionName
                        )
                }
            }
            if var closeProjection =
                pendingRemoteCloseProjections[completed.target] {
                closeProjection.projectedSessionOrder =
                    PaneCloseProjection.sessionOrder(
                        closeProjection.projectedSessionOrder,
                        afterSplitting: completed.sourceSessionName,
                        created: createdSessionName,
                        direction: completed.direction
                    ).filter {
                        !closeProjection.removedSessionNames.contains($0)
                    }
                pendingRemoteCloseProjections[completed.target] =
                    closeProjection
            }
        }
        guard completed.shouldFocus else { return }
        let projectedSessionOrder: [String]
        if let createdSessionName {
            projectedSessionOrder = PaneCloseProjection.sessionOrder(
                completed.existingSessionOrder,
                afterSplitting: completed.sourceSessionName,
                created: createdSessionName,
                direction: completed.direction
            )
        } else {
            projectedSessionOrder = completed.existingSessionOrder
        }
        pendingRemoteSplitFocusResults.append(
            PendingRemoteSplitFocusResult(
                target: completed.target,
                existingSessionNames: completed.existingSessionNames,
                expectedSessionName: createdSessionName,
                focusGeneration: completed.focusGeneration,
                projectedSessionOrder: projectedSessionOrder,
                removedSessionName: nil
            )
        )
    }

    private func resolveLegacyRemoteSplits(
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]]
    ) {
        let candidates = pendingRemoteSplitFocus.filter {
            $0.isDispatched && $0.legacySucceeded
        }
        for candidate in candidates {
            guard let index = pendingRemoteSplitFocus.firstIndex(
                where: { $0.id == candidate.id }
            ),
            let layout = worktreePanesByRemote[candidate.target.identity]?
                .first(where: {
                    $0.path == candidate.target.worktreePath
                        && ($0.origin?.relayDepth ?? 0) == 0
                })?.layout,
            (pendingRemoteCloseProjections[candidate.target]?
                .removedSessionNames.isDisjoint(
                    with: Set(layout.leaves.map(\.sessionName))
                ) ?? true),
            let newSessionName = layout.leaves.lazy.map(\.sessionName)
                .first(where: {
                    !candidate.existingSessionNames.contains($0)
                }),
            model.savedRemoteMacs.contains(where: {
                RemoteMacIdentity($0) == candidate.target.identity
            }) else {
                continue
            }
            let completed = pendingRemoteSplitFocus.remove(at: index)
            pendingRemoteMutationOrder.removeAll {
                $0 == completed.id
            }
            if remoteMutationInFlight == completed.id {
                remoteMutationInFlight = nil
            }
            completeRemoteSplit(
                completed,
                createdSessionName: newSessionName
            )
            dispatchNextRemoteMutation()
        }
    }

    private func completeRemotePaneControl(
        _ completed: PendingRemotePaneControl,
        response: PaneControlResponse
    ) {
        pendingRemotePaneControls.removeAll { $0.id == completed.id }
        pendingRemoteMutationOrder.removeAll { $0 == completed.id }
        if remoteMutationInFlight == completed.id {
            remoteMutationInFlight = nil
        }
        if response.isSuccess,
           case .close(let closedSessionName) = completed.request,
           let completedProjection = completed.closeProjection {
            let replacement = completedProjection.replacementTarget
            var closeProjection = pendingRemoteCloseProjections[
                completed.target
            ] ?? PendingRemoteCloseProjection(
                removedSessionNames: [],
                projectedSessionOrder: completedProjection.sessionOrder
            )
            closeProjection.removedSessionNames.insert(closedSessionName)
            closeProjection.projectedSessionOrder =
                completedProjection.sessionOrder.filter {
                    !closeProjection.removedSessionNames.contains($0)
                }
            pendingRemoteCloseProjections[completed.target] = closeProjection
            pendingRemoteSplitFocusResults.removeAll {
                $0.target == completed.target
                    && $0.focusGeneration == completed.focusGeneration
            }
            if selectedRemoteIdentity == completed.target.identity,
               selectedRemoteWorktreePath
                == completed.target.worktreePath {
                let currentGeneration = remotePaneIntentGeneration
                let currentProjection =
                    pendingRemoteSplitFocusResults.last(where: {
                        $0.target == completed.target
                            && $0.focusGeneration == currentGeneration
                    })
                let projectedSessionOrder =
                    closeProjection.projectedSessionOrder
                let currentSessionName =
                    currentProjection?.expectedSessionName
                    ?? selectedRemotePaneSessionName
                let projectedSessionName = currentSessionName.flatMap {
                    $0 != closedSessionName
                        && projectedSessionOrder.contains($0) ? $0 : nil
                } ?? projectedSessionOrder.first
                pendingRemoteSplitFocusResults.removeAll {
                    $0.target == completed.target
                        && $0.focusGeneration == currentGeneration
                }
                pendingRemoteSplitFocusResults.append(
                    PendingRemoteSplitFocusResult(
                        target: completed.target,
                        existingSessionNames: [],
                        expectedSessionName: projectedSessionName,
                        focusGeneration: currentGeneration,
                        projectedSessionOrder: projectedSessionOrder,
                        removedSessionName: closedSessionName
                    )
                )
                selectedRemotePaneSessionName = projectedSessionName
                pendingRemoteFocusTarget = completed.target
                let closedKey = RemoteTerminalKey(
                    identity: completed.target.identity,
                    worktreePath: completed.target.worktreePath,
                    sessionName: closedSessionName
                )
                if let closedID = remoteTerminalSlots[closedKey] {
                    splitTree =
                        splitTree.removing(closedID)
                    surfaces.setVisible(false, for: closedID)
                }
                if let projectedSessionName,
                   let replacementID = remoteTerminalSlots[
                    RemoteTerminalKey(
                    identity: completed.target.identity,
                    worktreePath: completed.target.worktreePath,
                    sessionName: projectedSessionName
                    )
                ] {
                    focusRemotePane(
                        replacementID,
                        target: completed.target
                    )
                }
            }
            for index in pendingRemoteSplitFocus.indices
            where pendingRemoteSplitFocus[index].target
                == completed.target {
                pendingRemoteSplitFocus[index].existingSessionOrder.removeAll {
                    $0 == closedSessionName
                }
                if let replacement,
                   pendingRemoteSplitFocus[index].sourceSessionName
                    == closedSessionName {
                    pendingRemoteSplitFocus[index].sourceSessionName =
                        replacement
                }
            }
            for index in pendingRemotePaneControls.indices
            where pendingRemotePaneControls[index].target
                == completed.target {
                if var projection =
                    pendingRemotePaneControls[index].closeProjection {
                    projection.projectClose(
                        from: closedSessionName,
                        to: replacement,
                        inheritsFocus: true
                    )
                    pendingRemotePaneControls[index].closeProjection =
                        projection
                    pendingRemotePaneControls[index].request = .close(
                        target: projection.target
                    )
                } else if let replacement {
                    pendingRemotePaneControls[index].request =
                        pendingRemotePaneControls[index].request
                        .rebasingTarget(
                            from: closedSessionName,
                            to: replacement
                        )
                }
            }
            if replacement == nil {
                let doomedSplitIDs = pendingRemoteSplitFocus
                    .filter {
                        $0.target == completed.target
                            && $0.sourceSessionName
                                == closedSessionName
                    }
                    .map(\.id)
                let doomedControlIDs = pendingRemotePaneControls
                    .filter {
                        $0.target == completed.target
                            && $0.request.rebasingTarget(
                                from: closedSessionName,
                                to: "__closed-pane__"
                            ) != $0.request
                    }
                    .map(\.id)
                let doomedIDs = Set(
                    doomedSplitIDs + doomedControlIDs
                )
                pendingRemoteSplitFocus.removeAll {
                    doomedIDs.contains($0.id)
                }
                pendingRemotePaneControls.removeAll {
                    doomedIDs.contains($0.id)
                }
                pendingRemoteMutationOrder.removeAll {
                    doomedIDs.contains($0)
                }
            }
        }
        dispatchNextRemoteMutation()
    }

    private func suppressPendingRemoteSplitFocus() {
        remotePaneIntentGeneration &+= 1
        for index in pendingRemoteSplitFocus.indices {
            pendingRemoteSplitFocus[index].shouldFocus = false
            pendingRemoteSplitFocus[index].previousZoomedSessionName = nil
        }
        pendingRemoteSplitFocusResults.removeAll()
    }

    private func setRemoteSurfacesVisible(_ visible: Bool) {
        guard let identity = selectedRemoteIdentity,
              let worktreePath = selectedRemoteWorktreePath else { return }
        for (key, terminalID) in remoteTerminalSlots
        where key.identity == identity && key.worktreePath == worktreePath {
            surfaces.setVisible(visible, for: terminalID)
        }
    }

    private func destroyRemoteSurfaces(
        identity: RemoteMacIdentity,
        worktreePath: String
    ) {
        let keys = remoteTerminalSlots.keys.filter {
            $0.identity == identity && $0.worktreePath == worktreePath
        }
        for key in keys {
            scheduledRemoteTerminalRetries.remove(key)
            openingRemoteTerminals[key] = nil
            if let terminalID = remoteTerminalSlots.removeValue(forKey: key) {
                surfaces.destroySurface(terminalID: terminalID)
            }
        }
    }

    private func destroyRemoteSurfaces(identity: RemoteMacIdentity) {
        let worktreePaths = Set(remoteTerminalSlots.keys.compactMap {
            $0.identity == identity ? $0.worktreePath : nil
        })
        for worktreePath in worktreePaths {
            destroyRemoteSurfaces(
                identity: identity,
                worktreePath: worktreePath
            )
        }
    }

    func destroyAllRemoteSurfaces() {
        for terminalID in remoteTerminalSlots.values {
            surfaces.destroySurface(terminalID: terminalID)
        }
        remoteTerminalSlots.removeAll()
        openingRemoteTerminals.removeAll()
        scheduledRemoteTerminalRetries.removeAll()
        splitTree = SplitTree(root: nil)
    }

    private func focusRemotePane(
        _ terminalID: PaneSlotID,
        target: WorktreeKey
    ) {
        guard selectedRemoteIdentity == target.identity,
              selectedRemoteWorktreePath == target.worktreePath,
              focusedTerminalID == terminalID else { return }
        surfaces.setFocus(terminalID)
        surfaces.promoteToFirstResponder(
            terminalID,
            when: { [self] in
                selectedRemoteIdentity == target.identity
                    && selectedRemoteWorktreePath == target.worktreePath
                    && focusedTerminalID == terminalID
            }
        ) { [self] in
            guard selectedRemoteIdentity == target.identity,
                  selectedRemoteWorktreePath == target.worktreePath,
                  pendingRemoteFocusTarget == target else { return }
            pendingRemoteFocusTarget = nil
        }
    }
}

extension RemoteMacsModel: RemoteWorktreeViewerModel {
    func connectViewer(to remoteMac: RemoteMac) async throws {
        _ = try await connect(to: remoteMac)
    }

    func openViewerTerminalSession(identity: RemoteMacIdentity, sessionName: String) async throws
        -> any WebSocketClient & Sendable {
        try await openTerminalSession(identity: identity, sessionName: sessionName)
    }
}

extension TerminalManager: RemoteWorktreeViewerSurfaces {
    func hasRemoteSurface(_ terminalID: PaneSlotID) -> Bool {
        view(for: terminalID) != nil
    }

    func createRemoteSurface(
        terminalID: PaneSlotID,
        worktreePath: String,
        client: any WebSocketClient & Sendable,
        onUnexpectedClose: @escaping () -> Void,
        agentCompletions: @escaping () async throws -> [AgentCompletionCandidate]
    ) -> Bool {
        let backend = RemoteTerminalSurfaceBackend(
            client: client,
            onUnexpectedClose: onUnexpectedClose
        )
        guard createSurface(
            terminalID: terminalID,
            paneSessionID: PaneSessionID(id: terminalID.id),
            worktreePath: worktreePath,
            hostManagedBackend: backend
        ) != nil else {
            return false
        }
        if let view = handle(for: terminalID)?.view as? SurfaceNSView {
            view.configureAgentCompletion(currentWorktreePath: worktreePath, loader: agentCompletions)
        }
        return true
    }

    /// Promote the terminal's backing `NSView` to the window's first
    /// responder so keyDown events route to libghostty. Dispatched async
    /// because the view may have just been created by `createSurfaces` and
    /// SwiftUI hasn't attached it to the window hierarchy yet — you can't
    /// `makeFirstResponder` a view that isn't in a window.
    func promoteToFirstResponder(
        _ terminalID: PaneSlotID,
        when shouldFocus: (() -> Bool)? = nil,
        onFocused: (() -> Void)? = nil
    ) {
        attemptPromoteToFirstResponder(
            terminalID,
            when: shouldFocus,
            onFocused: onFocused,
            attemptsRemaining: 20
        )
    }

    /// SwiftUI can take more than one run-loop turn to mount a newly selected
    /// worktree's terminal. Retry for a bounded interval, and only force the
    /// deferred zmx attach after AppKit has supplied a real grid. The normal
    /// layout notifier usually wins; `startForBackgroundLaunch` is one-shot
    /// and acts as a fallback for the UI-add path that previously left a
    /// mounted pane with no live session.
    private func attemptPromoteToFirstResponder(
        _ terminalID: PaneSlotID,
        when shouldFocus: (() -> Bool)?,
        onFocused: (() -> Void)?,
        attemptsRemaining: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: attemptsRemaining == 20 ? .now() : .now() + 0.05) { [self] in
            guard !NSApp.isHidden, shouldFocus?() ?? true else { return }
            guard let view = view(for: terminalID),
                  let window = view.window,
                  view.bounds.width > 0,
                  view.bounds.height > 0 else {
                guard attemptsRemaining > 1 else { return }
                attemptPromoteToFirstResponder(
                    terminalID,
                    when: shouldFocus,
                    onFocused: onFocused,
                    attemptsRemaining: attemptsRemaining - 1
                )
                return
            }
            _ = handle(for: terminalID)?.startForBackgroundLaunch()
            setVisible(true, for: terminalID)
            guard window.makeFirstResponder(view) else { return }
            onFocused?()
        }
    }
}
