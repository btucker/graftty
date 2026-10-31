import SwiftUI
import GrafttyKit

/// The local handlers behind `TerminalManager`'s pane callbacks: splits,
/// closes, focus, zoom, resize, pane moves, config reloads, and shell
/// integration pings. Pane-layout commands (split, close, surface closed,
/// focus, zoom, resize, equalize) reach them through
/// `TerminalManager.dispatchPaneCommand`, after any host-managed pane's
/// handler has had the chance to claim the command; the others fire
/// directly.
///
/// `GrafttyApp.startup()` calls `install` once.
@MainActor
enum TerminalPaneActions {
    static func install(
        on terminalManager: TerminalManager,
        appState: Binding<AppState>,
        remoteBranchStore: RemoteBranchStore,
        sessionRegistry: ClaudeSessionRegistry
    ) {
        // Route context-menu split requests through the same insertion code
        // path that Cmd+D uses, but targeting the *menu's* surface rather
        // than the currently-focused one — the two can differ if the user
        // right-clicks an unfocused pane.
        terminalManager.onSplitRequest = { [appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                _ = PaneCommands.splitPane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID,
                    split: direction
                )
            }
        }

        terminalManager.onOpenInEditorPane = { [appState, tm = terminalManager] terminalID, initialInput in
            Task { @MainActor in
                _ = PaneCommands.splitPane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID,
                    split: .right,
                    extraInitialInput: initialInput
                )
            }
        }

        // TERM-8.10 / PWD-1.4: terminal surface menu and sidebar drag
        // both route through this callback to share the existing
        // PWD-2.x reassignment pipeline.
        terminalManager.onMovePane = { [appState, tm = terminalManager] terminalID, destinationPath in
            MainActor.assumeIsolated {
                PaneCommands.reassignPaneByPWD(
                    appState: appState,
                    terminalManager: tm,
                    terminalID: terminalID,
                    newPWD: destinationPath
                )
            }
        }

        // Surface menu (`SurfaceContextMenu`) calls this at right-click
        // time so the snapshot is fresh; nil makes it skip the Move
        // section (e.g. mid-reassignment race window).
        terminalManager.currentPaneMoveContext = { [appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                let state = appState.wrappedValue
                let defaultBranches = PaneMoveMenuContext.defaultBranches(
                    for: state.repos,
                    using: remoteBranchStore
                )
                return PaneMoveMenuContext.resolve(
                    terminalID: terminalID,
                    appState: state,
                    shellCwd: tm.shellCwd(for: terminalID),
                    defaultBranchesByRepoPath: defaultBranches
                )
            }
        }

        // A user-issued close action targets the pane that emitted it.
        terminalManager.onCloseRequest = { [appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                switch paneCloseAction() {
                case .closePane:
                    PaneCommands.closePane(
                        appState: appState,
                        terminalManager: tm,
                        targetID: terminalID,
                        userInitiated: true
                    )
                }
            }
        }

        // A surface can also disappear because its shell exited or, for a
        // host-managed proxy, its transport dropped. Keep that distinct from
        // user close so a network failure cannot kill the owning Mac's pane.
        terminalManager.onSurfaceClosed = {
            [appState, tm = terminalManager] terminalID in
            MainActor.assumeIsolated {
                PaneCommands.closePane(
                    appState: appState,
                    terminalManager: tm,
                    targetID: terminalID
                )
            }
        }

        terminalManager.onGotoSplit = { [appState, tm = terminalManager] terminalID, direction in
            MainActor.assumeIsolated {
                PaneCommands.navigatePane(
                    appState: appState,
                    terminalManager: tm,
                    from: terminalID,
                    direction: direction
                )
            }
        }

        terminalManager.onGotoSplitOrder = { [appState, tm = terminalManager] terminalID, forward in
            MainActor.assumeIsolated {
                PaneCommands.navigatePaneInTreeOrder(
                    appState: appState,
                    terminalManager: tm,
                    from: terminalID,
                    forward: forward
                )
            }
        }

        terminalManager.onToggleZoom = { [appState] terminalID in
            MainActor.assumeIsolated {
                PaneCommands.toggleZoom(appState: appState, on: terminalID)
            }
        }

        terminalManager.onResizeSplit = { [appState] terminalID, direction, amount in
            MainActor.assumeIsolated {
                _ = PaneCommands.resizeSplit(
                    appState: appState,
                    target: terminalID,
                    direction: direction,
                    pixels: amount
                )
            }
        }

        terminalManager.onEqualizeSplits = { [appState] terminalID in
            MainActor.assumeIsolated {
                PaneCommands.equalizeSplits(appState: appState, around: terminalID)
            }
        }

        // `ghostty_app_update_config` re-reads the config files and swaps
        // them into the live app; our bridge rebuild happens inside
        // `reloadGhosttyConfig`. TERM-9.1.
        terminalManager.onReloadConfig = { [tm = terminalManager] in
            MainActor.assumeIsolated {
                tm.reloadGhosttyConfig()
            }
        }

        // Ghostty keybind mapped to `open_config` → same flow as the
        // "Open Ghostty Settings" menu item: resolve the config path,
        // create it if missing, hand to NSWorkspace. TERM-9.2.
        terminalManager.onOpenConfig = {
            MainActor.assumeIsolated {
                GrafttyApp.openGhosttySettings()
            }
        }

        // Shell integration semantic pings → sidebar attention badge on
        // the owning worktree. The badge is auto-clearing (3s) so it
        // behaves like a "ping", not a permanent state the user has to
        // dismiss. Non-zero exit codes get a longer (8s) dwell so the
        // user has a chance to notice errors across a worktree they're
        // not currently viewing.
        terminalManager.onCommandFinished = { [appState, sessionRegistry] terminalID, exitCode, _ in
            MainActor.assumeIsolated {
                if let indices = appState.wrappedValue.indicesOfWorktreeContaining(terminalID: terminalID),
                   let session = appState.wrappedValue.repos[indices.repo].worktrees[indices.worktree].paneSessions[terminalID] {
                    sessionRegistry.removePane(ZmxLauncher.sessionName(for: session))
                }
                PaneCommands.setAttentionForTerminal(
                    appState: appState,
                    terminalID: terminalID,
                    text: exitCode == 0 ? "✓" : "!",
                    clearAfter: exitCode == 0 ? 3 : 8,
                    source: .commandFinished
                )
            }
        }
        // PROGRESS_REPORT is intentionally unhandled: shell-integration
        // progress pings (OSC 9;4 from tools emitting indeterminate or
        // percent status) were too loud relative to the urgency they
        // convey. TerminalManager ignores the action; add a dedicated,
        // less-aggressive visual if the need comes back.

        // Explicit startup input has already been handed to shell startup.
        terminalManager.onShellReady = { [tm = terminalManager] terminalID in
            MainActor.assumeIsolated { _ = tm.consumeExplicitInitialInputMarker(terminalID) }
        }

    }
}
