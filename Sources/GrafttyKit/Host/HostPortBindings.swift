import Foundation
import GrafttyProtocol

public extension HeadlessHostRuntime {
    /// Poll independently of Git metadata. Only currently running, live zmx
    /// sessions can contribute listeners to the wire snapshot.
    func refreshPortBindings() async {
        guard !portScanInFlight else { return }
        portScanInFlight = true
        defer { portScanInFlight = false }
        let desired = currentPortSessions()
        let live = (try? await terminals.sessions()) ?? []
        let launcher = self.launcher
        let pids = await Task.detached(priority: .utility) {
            var result: [PaneSlotID: Int32] = [:]
            for (slot, session) in desired where live.contains(session) {
                if let pid = ZmxPIDLookup.shellPID(logFile: launcher.logFile(forSession: session), sessionName: session), pid > 0 {
                    result[slot] = pid
                }
            }
            return result
        }.value
        let current = currentPortSessions()
        for slot in registeredPortSessions.keys where current[slot] != registeredPortSessions[slot] {
            await portScanner.unregisterPane(slot)
        }
        for (slot, session) in desired where current[slot] == session {
            if let pid = pids[slot] {
                await portScanner.registerPane(slot, shellPID: pid)
            } else {
                await portScanner.unregisterPane(slot)
            }
        }
        registeredPortSessions = current
        await portScanner.tick()
        let latest = currentPortSessions()
        var bindings: [PaneSlotID: [PortBinding]] = [:]
        for (slot, session) in desired where latest[slot] == session {
            bindings[slot] = await portScanner.bindings(for: slot)
        }
        portBindingsByPane = bindings
        portBindingSessions = desired
    }
}

extension HeadlessHostRuntime {
    func currentPortSessions() -> [PaneSlotID: String] {
        var result: [PaneSlotID: String] = [:]
        for repo in state.repos {
            for worktree in repo.worktrees where worktree.state == .running {
                for slot in worktree.splitTree.allLeaves {
                    if let session = worktree.paneSessions[slot] { result[slot] = launcher.sessionName(for: session) }
                }
            }
        }
        return result
    }

    func wirePortBindings(for worktree: WorktreeEntry) -> [String: [PortBinding]] {
        guard worktree.state == .running else { return [:] }
        var result: [String: [PortBinding]] = [:]
        for slot in worktree.splitTree.allLeaves {
            guard let session = worktree.paneSessions[slot] else { continue }
            let name = launcher.sessionName(for: session)
            result[name] = portBindingSessions[slot] == name ? (portBindingsByPane[slot] ?? []) : []
        }
        return result
    }
}
