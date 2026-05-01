import Combine
import Foundation

@MainActor
final class PaneTitleInvalidationSource: ObservableObject {
    @Published private(set) var generation: UInt = 0

    private var pendingTask: Task<Void, Never>?

    func schedule() {
        guard pendingTask == nil else { return }
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.generation &+= 1
            self.pendingTask = nil
        }
    }

    @discardableResult
    func flushPendingForTests() -> Bool {
        guard pendingTask != nil else { return false }
        pendingTask?.cancel()
        pendingTask = nil
        generation &+= 1
        return true
    }
}
