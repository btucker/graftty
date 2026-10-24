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
    private var corruptBackupFailed = false

    private enum BackgroundRead: Sendable {
        case loaded([Element])
        case malformed
    }

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
        let isLoadable = isLoadable
        let loaded: BackgroundRead = await withCheckedContinuation { continuation in
            // File reads can block; leave Swift's cooperative workers available.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.readInBackground(file, isLoadable: isLoadable))
            }
        }
        guard !hasLoaded else { return }
        switch loaded {
        case .loaded(let rows):
            elements = rows.sorted(by: areInIncreasingOrder)
            hasLoaded = true
        case .malformed:
            // Re-read on the owning actor before recovery. A background read
            // must never rename a file that a later write has replaced.
            switch corruptFile {
            case .moveAside: ensureLoaded()
            case .discard:
                elements = []
                hasLoaded = true
            }
        }
    }

    /// Sync fallback for mutations that race ahead of `loadIfNeeded()`.
    /// No-op when already loaded.
    public func ensureLoaded() {
        guard !hasLoaded else { return }
        do {
            elements = try Self.read(file, corruptFile: corruptFile, isLoadable: isLoadable)
                .sorted(by: areInIncreasingOrder)
        } catch {
            corruptBackupFailed = true
            NSLog("[Graftty] failed to back up corrupt %@: %@", file.fileURL.path, String(describing: error))
        }
        hasLoaded = true
    }

    /// Persists `list` and, only once the write succeeds, publishes it as
    /// loaded, so a pending `loadIfNeeded()` cannot replace it.
    public func write(_ list: [Element]) throws {
        if corruptBackupFailed {
            _ = try file.loadMovingAsideCorruptFile(ignoringReadErrors: false)
        }
        try file.save(list)
        elements = list.sorted(by: areInIncreasingOrder)
        hasLoaded = true
        corruptBackupFailed = false
    }

    nonisolated private static func read(
        _ file: JSONFileStore<[Element]>,
        corruptFile: CorruptFilePolicy,
        isLoadable: (Element) -> Bool
    ) throws -> [Element] {
        let rows = switch corruptFile {
        case .moveAside: try file.loadMovingAsideCorruptFile()
        case .discard: try? file.load()
        }
        return (rows ?? []).filter(isLoadable)
    }

    nonisolated private static func readInBackground(
        _ file: JSONFileStore<[Element]>,
        isLoadable: (Element) -> Bool
    ) -> BackgroundRead {
        do {
            return .loaded((try file.load() ?? []).filter(isLoadable))
        } catch is DecodingError {
            return .malformed
        } catch {
            return .loaded([])
        }
    }
}
