// Sources/GrafttyKit/Ports/ProcessTreeWalker.swift
import Foundation
import Darwin

public protocol ProcessTreeWalking: Sendable {
    /// All PIDs in the subtree rooted at `root`, inclusive. Returns
    /// `[root]` if no descendants. Returns `[]` if `root` is not a live PID.
    func descendants(of root: pid_t) -> [pid_t]

    /// Bulk variant: returns descendants for many roots at once. Concrete
    /// implementations should share the parent-table build across roots.
    func descendants(rootedAt roots: [pid_t]) -> [pid_t: [pid_t]]
}

public extension ProcessTreeWalking {
    /// Default: call `descendants(of:)` per root. Concrete walkers can
    /// override for shared-cost batching.
    func descendants(rootedAt roots: [pid_t]) -> [pid_t: [pid_t]] {
        var result: [pid_t: [pid_t]] = [:]
        for root in roots { result[root] = descendants(of: root) }
        return result
    }
}

public struct ProcessTreeWalker: ProcessTreeWalking, Sendable {
    public init() {}

    /// All PIDs in the subtree rooted at `root`, inclusive. Returns
    /// `[root]` if no descendants. Returns `[]` if `root` is not a live PID.
    public func descendants(of root: pid_t) -> [pid_t] {
        guard isLive(pid: root) else { return [] }
        let parents = parentTable()
        var children: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in parents {
            children[ppid, default: []].append(pid)
        }
        var result: [pid_t] = [root]
        var queue: [pid_t] = [root]
        while let next = queue.popLast() {
            for child in children[next, default: []] {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    public func descendants(rootedAt roots: [pid_t]) -> [pid_t: [pid_t]] {
        let parents = parentTable()
        var children: [pid_t: [pid_t]] = [:]
        var known: Set<pid_t> = []
        for (pid, ppid) in parents {
            children[ppid, default: []].append(pid)
            known.insert(pid)
        }
        var result: [pid_t: [pid_t]] = [:]
        for root in roots {
            guard known.contains(root) else { result[root] = []; continue }
            var subtree: [pid_t] = [root]
            var queue: [pid_t] = [root]
            while let next = queue.popLast() {
                for child in children[next, default: []] {
                    subtree.append(child)
                    queue.append(child)
                }
            }
            result[root] = subtree
        }
        return result
    }

    private func parentTable() -> [(pid_t, pid_t)] {
        let nbytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard nbytes > 0 else { return [] }
        let count = Int(nbytes) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let written = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, Int32(nbytes))
        }
        guard written > 0 else { return [] }
        let live = pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
        return live.compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
            guard r == size else { return nil }
            return (pid, pid_t(info.pbi_ppid))
        }
    }

    private func isLive(pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
    }
}
