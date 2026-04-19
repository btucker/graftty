import Foundation

/// `PWD-1.3` dedup core: fires `onChange` only when a tracked pane's
/// resolved cwd differs from its last-known value. `seed(_:pwd:)`
/// updates that memory without firing — the OSC 7 path calls it to
/// keep the two sources from dispatching the same cd twice.
@MainActor
public final class SurfacePWDPoller {

    public typealias CwdResolver = (TerminalID) -> String?
    public typealias ChangeHandler = (TerminalID, String) -> Void

    private let resolve: CwdResolver
    private let onChange: ChangeHandler
    private var tracked: Set<TerminalID> = []
    private var lastKnown: [TerminalID: String] = [:]

    public init(resolve: @escaping CwdResolver, onChange: @escaping ChangeHandler) {
        self.resolve = resolve
        self.onChange = onChange
    }

    public func track(_ id: TerminalID) {
        tracked.insert(id)
    }

    public func untrack(_ id: TerminalID) {
        tracked.remove(id)
        lastKnown.removeValue(forKey: id)
    }

    /// Update the last-known cwd for `id` without invoking `onChange`.
    public func seed(_ id: TerminalID, pwd: String) {
        lastKnown[id] = pwd
    }

    /// Resolver returning nil is treated as "no signal" — last-known
    /// is untouched so a future successful resolve still fires.
    public func pollOnce() {
        for id in tracked {
            guard let pwd = resolve(id) else { continue }
            if lastKnown[id] != pwd {
                lastKnown[id] = pwd
                onChange(id, pwd)
            }
        }
    }
}
