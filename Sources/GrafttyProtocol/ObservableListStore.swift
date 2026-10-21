import Foundation
import Observation

/// @spec PERSIST-5.5
/// When an ObservableListStore is mutated before its asynchronous load
/// completes, the application shall first load the persisted rows
/// synchronously so the write builds on them instead of replacing them with
/// an empty list.
///
/// A main-actor list persisted as one JSON array through `JSONFileStore`.
///
/// `init` performs no I/O, so stores can be built on a launch path.
/// `loadIfNeeded()` reads off the main actor; mutations call
/// `ensureLoaded()` first so a write that races ahead of the async load
/// builds on the persisted rows instead of clobbering them with an empty
/// list. A missing or unreadable file reads as empty; malformed contents
/// read as empty and are moved aside only under `.moveAside`.
@MainActor
@Observable
public final class ObservableListStore<Element: Codable & Sendable> {

    public enum CorruptFilePolicy: Sendable {
        /// Keep the unreadable file beside the original before the next write replaces it.
        case moveAside
        /// Let the next write replace it.
        case discard
    }

    /// Always sorted by the store's ordering.
    public private(set) var elements: [Element] = []

    /// Distinguishes "loaded, empty" from "load not yet completed".
    public private(set) var hasLoaded = false

    private let file: JSONFileStore<[Element]>
    private let corruptFile: CorruptFilePolicy
    private let isLoadable: @Sendable (Element) -> Bool
    private let areInIncreasingOrder: (Element, Element) -> Bool

    /// - Parameters:
    ///   - isLoadable: Rows that fail it are dropped on read (e.g. pairings
    ///     from an older protocol version).
    ///   - areInIncreasingOrder: The order `elements` is kept in.
    public init(
        file: JSONFileStore<[Element]>,
        corruptFile: CorruptFilePolicy,
        isLoadable: @escaping @Sendable (Element) -> Bool = { _ in true },
        areInIncreasingOrder: @escaping (Element, Element) -> Bool
    ) {
        self.file = file
        self.corruptFile = corruptFile
        self.isLoadable = isLoadable
        self.areInIncreasingOrder = areInIncreasingOrder
    }

    /// Idempotent. Call from a SwiftUI `.task` so the JSON read runs
    /// after the first frame commits.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        let file = file
        let corruptFile = corruptFile
        let isLoadable = isLoadable
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.read(file, corruptFile: corruptFile, isLoadable: isLoadable)
        }.value
        guard !hasLoaded else { return }
        elements = loaded.sorted(by: areInIncreasingOrder)
        hasLoaded = true
    }

    /// Sync fallback for mutations that race ahead of `loadIfNeeded()`.
    /// No-op when already loaded.
    public func ensureLoaded() {
        guard !hasLoaded else { return }
        elements = Self.read(file, corruptFile: corruptFile, isLoadable: isLoadable)
            .sorted(by: areInIncreasingOrder)
        hasLoaded = true
    }

    /// Persists `list` and, only once the write succeeds, publishes it.
    public func write(_ list: [Element]) throws {
        try file.save(list)
        elements = list.sorted(by: areInIncreasingOrder)
    }

    nonisolated private static func read(
        _ file: JSONFileStore<[Element]>,
        corruptFile: CorruptFilePolicy,
        isLoadable: (Element) -> Bool
    ) -> [Element] {
        do {
            return try (file.load() ?? []).filter(isLoadable)
        } catch is DecodingError {
            if corruptFile == .moveAside {
                file.moveAsideCorruptFile()
            }
            return []
        } catch {
            return []
        }
    }
}
