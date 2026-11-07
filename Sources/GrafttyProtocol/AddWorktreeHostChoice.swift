import Foundation

/// A host that has the project, as offered by Add Worktree.
public struct AddWorktreeHostChoice: Identifiable, Sendable, Equatable {
    public let id: String
    public let host: String
    public let path: String?
    public let availability: HostAvailability
    /// The path shows only when the host has two checkouts: see `labeled`.
    public var label: String

    public init(id: String, host: String, path: String?, availability: HostAvailability) {
        self.id = id; self.host = host; self.path = path; self.availability = availability
        self.label = host
    }

    /// A sleeping host can be chosen, which wakes it. Other offline hosts can't.
    public var isSelectable: Bool { availability != .offline }

    public static func showsRow(_ choices: [AddWorktreeHostChoice]) -> Bool { choices.count > 1 }

    public static func labeled(_ choices: [AddWorktreeHostChoice]) -> [AddWorktreeHostChoice] {
        let counts = Dictionary(choices.map { ($0.host, 1) }, uniquingKeysWith: +)
        return choices.map { choice in
            var result = choice
            if (counts[choice.host] ?? 0) > 1, let path = choice.path { result.label = "\(choice.host) · \(path)" }
            return result
        }
    }

    /// `wakesOnOpen` is true only when every selectable host needs reconnection, because
    /// opening the sheet needs a host to load branches from.
    public static func defaultChoice(_ choices: [AddWorktreeHostChoice], lastUsedID: String?)
        -> (choice: AddWorktreeHostChoice, wakesOnOpen: Bool)? {
        let selectable = choices.filter(\.isSelectable)
        guard let preferred = selectable.first(where: { $0.id == lastUsedID }) ?? selectable.first else { return nil }
        if preferred.availability == .reachable { return (preferred, false) }
        if let awake = selectable.first(where: { $0.availability == .reachable }) { return (awake, false) }
        return (preferred, true)
    }
}
