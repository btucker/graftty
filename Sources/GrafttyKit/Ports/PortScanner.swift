// Sources/GrafttyKit/Ports/PortScanner.swift
import Foundation

/// @spec PORTS-1.1: When a pane's foreground process is non-shell, the application shall scan that process subtree's TCP listening sockets every 2 seconds.
//
/// @spec PORTS-4.3: When a pane is dragged to another worktree, the application shall preserve its registration and binding snapshot (`PaneSlotID` is stable).
//
/// @spec PORTS-4.5: When a pane is registered before its shell PID can be resolved, the application shall record it as pending and re-attempt resolution on each scan tick.
public actor PortScanner {
    private let socketScanner: any PortSocketScanning
    private var generations: [PaneSlotID: UInt64] = [:]
    private var nextGeneration: UInt64 = 0
    private let walker: any ProcessTreeWalking
    private var registrations: [PaneSlotID: pid_t] = [:]
    private var pending: Set<PaneSlotID> = []
    private var snapshots: [PaneSlotID: [PortBinding]] = [:]
    private var inFlight = false

    /// Closure invoked on the main actor whenever a pane's binding set
    /// changes. Wired by `GrafttyApp` to push into `PortBindingsModel`.
    public private(set) var onChange: (@MainActor @Sendable (PaneSlotID, [PortBinding]) -> Void)?

    /// Resolver consulted on each tick for panes registered via
    /// `registerPanePending`. Returns the inner-shell PID if it is now
    /// resolvable, or `nil` if the call should be re-attempted next tick.
    private var pidResolver: (@Sendable (PaneSlotID) async -> pid_t?)?

    public init(runner: LsofRunner, walker: any ProcessTreeWalking) {
        self.socketScanner = LsofPortSocketScanner(runner: runner)
        self.walker = walker
    }

    public init(socketScanner: any PortSocketScanning, walker: any ProcessTreeWalking = ProcessTreeWalker()) {
        self.socketScanner = socketScanner
        self.walker = walker
    }

    public init() {
        #if os(Linux)
        socketScanner = LinuxProcSocketScanner()
        #else
        socketScanner = LsofPortSocketScanner()
        #endif
        walker = ProcessTreeWalker()
    }

    private func advanceGeneration(_ id: PaneSlotID) {
        nextGeneration &+= 1
        generations[id] = nextGeneration
    }

    public func setOnChange(_ callback: @escaping @MainActor @Sendable (PaneSlotID, [PortBinding]) -> Void) {
        self.onChange = callback
    }

    public func setPIDResolver(_ resolver: @escaping @Sendable (PaneSlotID) async -> pid_t?) {
        self.pidResolver = resolver
    }

    public func registerPane(_ id: PaneSlotID, shellPID: pid_t) {
        if registrations[id] != shellPID { advanceGeneration(id); updateSnapshot(id: id, bindings: []) }
        pending.remove(id)
        registrations[id] = shellPID
    }

    /// PORTS-4.5: Register a pane whose shell PID isn't yet resolvable
    /// (e.g., the zmx daemon hasn't written its `pty spawned` log line).
    /// The scanner re-attempts resolution via `pidResolver` on each tick
    /// and promotes the pane to a normal registration once it succeeds.
    public func registerPanePending(_ id: PaneSlotID) {
        guard registrations[id] == nil, !pending.contains(id) else { return }
        advanceGeneration(id)
        pending.insert(id)
    }

    public func unregisterPane(_ id: PaneSlotID) {
        generations[id] = nil
        pending.remove(id)
        registrations.removeValue(forKey: id)
        if snapshots.removeValue(forKey: id) != nil {
            let onChange = self.onChange
            Task { @MainActor in onChange?(id, []) }
        }
    }

    public func bindings(for id: PaneSlotID) -> [PortBinding] {
        snapshots[id] ?? []
    }

    public func tick() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        if let resolver = pidResolver, !pending.isEmpty {
            for id in pending {
                let generation = generations[id]
                let pid = await resolver(id)
                guard pending.contains(id), generations[id] == generation else { continue }
                if let pid, pid > 0 {
                    pending.remove(id)
                    registrations[id] = pid
                }
            }
        }

        let scanRegistrations = registrations
        let scanGenerations = generations
        let roots = Array(scanRegistrations.values)
        let descendantsByRoot = walker.descendants(rootedAt: roots)
        var paneToPIDs: [PaneSlotID: Set<pid_t>] = [:]
        var allPIDs: Set<pid_t> = []
        for (id, shell) in scanRegistrations {
            let descendants = Set(descendantsByRoot[shell] ?? [])
            paneToPIDs[id] = descendants
            allPIDs.formUnion(descendants)
        }
        guard !allPIDs.isEmpty else {
            applyEmpty()
            return
        }
        let rows = await socketScanner.listeningSockets(pids: allPIDs) ?? []
        for (id, pids) in paneToPIDs {
            guard registrations[id] == scanRegistrations[id], generations[id] == scanGenerations[id] else { continue }
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

    private func updateSnapshot(id: PaneSlotID, bindings: [PortBinding]) {
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
        var perPidPort: [Key: (scope: BindScope, name: String, target: String?)] = [:]
        for row in rows {
            let key = Key(pid: row.pid, port: row.port)
            let scope = scopeFor(address: row.address)
            let target = targetFor(address: row.address)
            if let existing = perPidPort[key] {
                let merged: BindScope = (existing.scope == .lan || scope == .lan) ? .lan : .loopback
                perPidPort[key] = (merged, existing.name, [existing.target, target].compactMap { $0 }.sorted().first)
            } else {
                perPidPort[key] = (scope, row.processName, target)
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
                pid: key.pid,
                targetHost: value.target
            )
            if let existing = grouped[gk] {
                if candidate.pid < existing.pid {
                    grouped[gk] = candidate
                }
            } else {
                grouped[gk] = candidate
            }
        }
        return grouped.values.sorted { $0.port == $1.port ? $0.scope.rawValue < $1.scope.rawValue : $0.port < $1.port }
    }

    static func scopeFor(address: String) -> BindScope {
        address == "::1" || isIPv4Loopback(address) ? .loopback : .lan
    }

    private static func isIPv4Loopback(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    private static func targetFor(address: String) -> String? {
        if address == "::1" || isIPv4Loopback(address) { return address }
        if address == "::" { return "::1" }
        if address == "0.0.0.0" || address == "*" { return "127.0.0.1" }
        return nil
    }
}
