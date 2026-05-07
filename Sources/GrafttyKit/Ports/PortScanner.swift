// Sources/GrafttyKit/Ports/PortScanner.swift
import Foundation
import os

/// @spec PORTS-1.1: When a pane's foreground process is non-shell, the application shall scan that process subtree's TCP listening sockets every 2 seconds.
//
/// @spec PORTS-4.3: When a pane is dragged to another worktree, the application shall preserve its registration and binding snapshot (`TerminalID` is stable).
public actor PortScanner {
    private let runner: LsofRunner
    private let walker: any ProcessTreeWalking
    private var registrations: [TerminalID: pid_t] = [:]
    private var snapshots: [TerminalID: [PortBinding]] = [:]
    private var inFlight = false
    private let log = Logger(subsystem: "com.btucker.graftty", category: "PortScanner")

    /// Closure invoked on the main actor whenever a pane's binding set
    /// changes. Wired by `GrafttyApp` to push into `PortBindingsModel`.
    public private(set) var onChange: (@MainActor @Sendable (TerminalID, [PortBinding]) -> Void)?

    public init(runner: LsofRunner, walker: any ProcessTreeWalking) {
        self.runner = runner
        self.walker = walker
    }

    public func setOnChange(_ callback: @escaping @MainActor @Sendable (TerminalID, [PortBinding]) -> Void) {
        self.onChange = callback
    }

    public func registerPane(_ id: TerminalID, shellPID: pid_t) {
        registrations[id] = shellPID
    }

    public func unregisterPane(_ id: TerminalID) {
        registrations.removeValue(forKey: id)
        if snapshots.removeValue(forKey: id) != nil {
            let onChange = self.onChange
            Task { @MainActor in onChange?(id, []) }
        }
    }

    public func bindings(for id: TerminalID) -> [PortBinding] {
        snapshots[id] ?? []
    }

    public func tick() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let roots = Array(registrations.values)
        let descendantsByRoot = walker.descendants(rootedAt: roots)
        var paneToPIDs: [TerminalID: Set<pid_t>] = [:]
        var allPIDs: Set<pid_t> = []
        for (id, shell) in registrations {
            let descendants = Set(descendantsByRoot[shell] ?? [])
            paneToPIDs[id] = descendants
            allPIDs.formUnion(descendants)
        }
        guard !allPIDs.isEmpty else {
            applyEmpty()
            return
        }
        let joined = allPIDs.sorted().map(String.init).joined(separator: ",")
        guard let raw = await runner.run(pids: joined) else {
            log.error("lsof failed; treating snapshot as empty")
            applyEmpty()
            return
        }
        let rows = LsofOutputParser.parse(raw)
        for (id, pids) in paneToPIDs {
            let paneRows = rows.filter { pids.contains($0.pid) }
            let bindings = Self.collapse(paneRows)
            updateSnapshot(id: id, bindings: bindings)
        }
    }

    private func applyEmpty() {
        for id in registrations.keys {
            updateSnapshot(id: id, bindings: [])
        }
    }

    private func updateSnapshot(id: TerminalID, bindings: [PortBinding]) {
        let prev = snapshots[id] ?? []
        guard prev != bindings else { return }
        snapshots[id] = bindings
        let onChange = self.onChange
        Task { @MainActor in onChange?(id, bindings) }
    }

    /// Dedupe rows by `(port, scope)` after broadening scope when *any*
    /// row for that pid+port is non-loopback. Choose lowest PID for ties.
    static func collapse(_ rows: [LsofOutputParser.Row]) -> [PortBinding] {
        struct Key: Hashable { let pid: pid_t; let port: UInt16 }
        var perPidPort: [Key: (scope: BindScope, name: String)] = [:]
        for row in rows {
            let key = Key(pid: row.pid, port: row.port)
            let scope = scopeFor(address: row.address)
            if let existing = perPidPort[key] {
                let merged: BindScope = (existing.scope == .lan || scope == .lan) ? .lan : .loopback
                perPidPort[key] = (merged, existing.name)
            } else {
                perPidPort[key] = (scope, row.processName)
            }
        }
        struct GKey: Hashable { let port: UInt16; let scope: BindScope }
        var grouped: [GKey: PortBinding] = [:]
        for (key, value) in perPidPort {
            let gk = GKey(port: key.port, scope: value.scope)
            let candidate = PortBinding(
                port: key.port,
                scope: value.scope,
                processName: value.name,
                pid: key.pid
            )
            if let existing = grouped[gk] {
                if candidate.pid < existing.pid {
                    grouped[gk] = candidate
                }
            } else {
                grouped[gk] = candidate
            }
        }
        return grouped.values.sorted { $0.port < $1.port }
    }

    static func scopeFor(address: String) -> BindScope {
        switch address {
        case "127.0.0.1", "::1": return .loopback
        default: return .lan
        }
    }
}
