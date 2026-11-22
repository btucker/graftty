import Foundation
import Observation

@Observable @MainActor
public final class WatchInboxModel {
    public enum ReplyState: Equatable { case idle, sending, sent, failed(String) }
    public typealias Send = @MainActor (WatchRequest) async throws -> WatchResponse

    public private(set) var snapshot: WatchAttentionSnapshot
    public private(set) var isRefreshing = false
    public private(set) var error: String?
    private var replies: [String: ReplyState] = [:]

    public init(snapshot: WatchAttentionSnapshot = .init()) { self.snapshot = snapshot }

    public func receive(_ snapshot: WatchAttentionSnapshot) {
        guard snapshot.updatedAt >= self.snapshot.updatedAt else { return }
        self.snapshot = snapshot
        // Omitted questions may return before their WCSession replies finish.
        // Keep their in-flight guard until acknowledgement arrives.
        let current = Set(snapshot.cards.map(\.questionID))
        replies = replies.filter { current.contains($0.key) || $0.value == .sending }
    }

    public func refresh(using send: Send) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        error = nil
        defer { isRefreshing = false }
        do {
            switch try await send(.refresh) {
            case .snapshot(let snapshot): receive(snapshot)
            case .failure(let message): error = message
            case .answered, .terminal: error = "The iPhone returned an unexpected response."
            }
        } catch { self.error = "Couldn't reach your iPhone. Your last update is still shown." }
    }

    public func replyState(for card: WatchAttentionCard) -> ReplyState { replies[card.questionID] ?? .idle }

    public func answer(_ card: WatchAttentionCard, text: String, using send: Send) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.isEnabled, card.target != nil, !text.isEmpty,
              snapshot.cards.contains(where: { $0.questionID == card.questionID && $0.target == card.target }),
              replyState(for: card) != .sending, replyState(for: card) != .sent else { return }
        replies[card.questionID] = .sending
        let state: ReplyState
        do {
            switch try await send(.answer(id: UUID(), card: card, text: text)) {
            case .answered: state = .sent
            case .failure(let message): state = .failed(message)
            case .snapshot, .terminal: state = .failed("The iPhone returned an unexpected response.")
            }
        } catch let error as WatchRequest.TransferError {
            state = .failed(error.localizedDescription)
        } catch {
            state = .failed("Delivery wasn't confirmed. Refresh before trying again.")
        }
        guard snapshot.cards.contains(where: { $0.questionID == card.questionID }) else {
            replies[card.questionID] = nil
            return
        }
        replies[card.questionID] = state
    }
}
