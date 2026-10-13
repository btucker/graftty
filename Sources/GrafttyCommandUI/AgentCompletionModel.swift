import SwiftUI
import GrafttyProtocol

public enum AgentCompletionKey { case up, down, accept, escape }

/// Keeps the token out of the PTY until acceptance or literal dismissal.
@MainActor
public final class AgentCompletionModel: ObservableObject {
    public typealias CatalogUpdate = @MainActor ([AgentCompletionCandidate]) -> Void
    @Published public private(set) var isActive = false
    @Published public private(set) var query = ""
    @Published public private(set) var candidates: [AgentCompletionCandidate] = []
    @Published public private(set) var selectedID: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadFailed = false
    public var loadCandidates: (() async throws -> [AgentCompletionCandidate])?
    public var loadCandidatesWithUpdates: ((@escaping CatalogUpdate) async throws -> [AgentCompletionCandidate])?
    public var onInsertText: ((String) -> Void)?
    public var onInsertLiteral: ((String) -> Void)?
    public var currentWorktreePath: String?
    private var catalog: [AgentCompletionCandidate] = []
    private var atWordBoundary = true
    private var loadTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init() {}

    public func handleText(_ text: String) -> Bool {
        guard loadCandidates != nil || loadCandidatesWithUpdates != nil,
              onInsertText != nil, !text.isEmpty else { return false }
        if isActive {
            if text.contains(where: { $0.isWhitespace || $0 == "%" })
                || text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                cancel(preserveLiteral: true)
                atWordBoundary = text.last?.isWhitespace == true
                return false
            }
            query += text
            filter()
            return true
        }
        if text == "%", atWordBoundary {
            isActive = true
            query = ""
            catalog = []
            filter()
            startLoad()
            return true
        }
        atWordBoundary = text.last?.isWhitespace == true
        return false
    }

    public func handleBackspace() -> Bool {
        guard isActive else { atWordBoundary = false; return false }
        if query.isEmpty {
            cancel(preserveLiteral: false)
            atWordBoundary = true
        } else {
            query.removeLast()
            filter()
        }
        return true
    }

    public func handleKey(_ key: AgentCompletionKey) -> Bool {
        guard isActive else { return false }
        switch key {
        case .escape: cancel(preserveLiteral: true)
        case .accept:
            if let selectedID { accept(selectedID) }
        case .up, .down:
            guard !candidates.isEmpty else { return true }
            let current = candidates.firstIndex { $0.id == selectedID } ?? 0
            let delta = key == .up ? -1 : 1
            selectedID = candidates[(current + delta + candidates.count) % candidates.count].id
        }
        return true
    }

    public func accept(_ id: String) {
        guard isActive, let candidate = candidates.first(where: { $0.id == id }),
              !candidate.address.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return }
        cancel(preserveLiteral: false)
        atWordBoundary = false
        onInsertText?(candidate.address)
    }

    public func cancel(preserveLiteral: Bool) {
        let literal = isActive && preserveLiteral ? "%" + query : nil
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        // UIKit can invalidate an already-idle picker during a SwiftUI update.
        // Publishing equal values here would schedule the same update again.
        if isActive { isActive = false }
        if !query.isEmpty { query = "" }
        catalog = []
        if !candidates.isEmpty { candidates = [] }
        if selectedID != nil { selectedID = nil }
        if isLoading { isLoading = false }
        if loadFailed { loadFailed = false }
        atWordBoundary = !preserveLiteral
        if let literal { (onInsertLiteral ?? onInsertText)?(literal) }
    }

    /// Call after cursor navigation or external input invalidates the boundary.
    public func invalidateBoundary() {
        cancel(preserveLiteral: true)
        atWordBoundary = false
    }

    public func waitForLoad() async { await loadTask?.value }

    private func startLoad() {
        let load = loadCandidates
        let loadWithUpdates = loadCandidatesWithUpdates
        guard load != nil || loadWithUpdates != nil else { return }
        generation &+= 1
        let requestGeneration = generation
        isLoading = true
        loadFailed = false
        loadTask = Task { [weak self] in
            do {
                let update: CatalogUpdate = { [weak self] entries in
                    guard let self, self.isActive, self.generation == requestGeneration else { return }
                    self.catalog = entries
                    self.filter()
                }
                let entries: [AgentCompletionCandidate]
                if let loadWithUpdates { entries = try await loadWithUpdates(update) }
                else { entries = try await load?() ?? [] }
                guard let self, self.isActive, self.generation == requestGeneration else { return }
                self.catalog = entries
                self.isLoading = false
                self.filter()
            } catch {
                guard let self, self.isActive, self.generation == requestGeneration else { return }
                self.isLoading = false
                self.loadFailed = true
            }
        }
    }

    private func filter() {
        candidates = AgentCompletionCandidate.matching(catalog, query: query, currentWorktreePath: currentWorktreePath)
        if !candidates.contains(where: { $0.id == selectedID }) { selectedID = candidates.first?.id }
    }
}
