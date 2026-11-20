import Foundation
import Testing
@testable import GrafttyWatchKit

@MainActor
struct WatchInboxTests {
    private func card(occurrence: String = "first", canReply: Bool = true) -> WatchAttentionCard {
        .init(hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
              worktreeID: "/repo/watch", project: "Graftty", worktree: "watch", host: "Mac",
              title: "Watch companion", question: "Ship it?", context: "The checks passed.",
              options: [.init(label: "Ship", cost: "Publish now", suggested: true)],
              target: canReply ? .init(paneID: "pane", occurrence: Data(occurrence.utf8)) : nil,
              timestamp: Date(timeIntervalSinceReferenceDate: 10))
    }

    @Test("@spec WATCH-1.1: When Apple Watch receives an attention snapshot, the application shall preserve each question's host, worktree, context, choices, and exact reply target across encoding and decoding.")
    func snapshotRoundTrip() throws {
        let snapshot = WatchAttentionSnapshot(cards: [card()], updatedAt: .now)
        let decoded = try JSONDecoder().decode(WatchAttentionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.cards[0].options[0].suggested)
        #expect(decoded.cards[0].target?.occurrence == Data("first".utf8))
    }

    @Test("@spec WATCH-1.2: If refreshing the watch inbox fails, then the application shall retain the last snapshot and show the failure instead of showing an empty inbox.")
    func failedRefreshKeepsContext() async {
        let snapshot = WatchAttentionSnapshot(cards: [card()], updatedAt: .now)
        let model = WatchInboxModel(snapshot: snapshot)
        await model.refresh { _ in throw URLError(.notConnectedToInternet) }
        #expect(model.snapshot == snapshot)
        #expect(model.error != nil)
        #expect(!model.isRefreshing)
    }

    @Test("@spec WATCH-1.3: When a watch reply is accepted by the host, the application shall mark that exact question as sent and prevent another submission while allowing a later question in the same worktree to be answered.")
    func successfulReplyIsScopedToTheQuestion() async {
        let first = card()
        let model = WatchInboxModel(snapshot: .init(cards: [first], updatedAt: .now))
        var sent: [WatchRequest] = []
        let send: WatchInboxModel.Send = { request in sent.append(request); return .answered }
        await model.answer(first, text: " Ship ", using: send)
        await model.answer(first, text: "Ship", using: send)
        #expect(sent.count == 1)
        #expect(model.replyState(for: first) == .sent)
        let second = card(occurrence: "second")
        model.receive(.init(cards: [second], updatedAt: .now))
        #expect(model.replyState(for: second) == .idle)
        await model.answer(second, text: "Wait", using: send)
        #expect(sent.count == 2)
    }

    @Test("@spec WATCH-1.4: While a watch reply awaits host acknowledgement, the application shall prevent duplicate submissions and show Sent only after the host accepts the answer.")
    func pendingReplyCannotBeSentTwice() async {
        let question = card()
        let model = WatchInboxModel(snapshot: .init(cards: [question], updatedAt: .now))
        var continuation: CheckedContinuation<WatchResponse, Error>?
        let task = Task {
            await model.answer(question, text: "Ship") { _ in
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        #expect(model.replyState(for: question) == .sending)
        await model.answer(question, text: "Ship") { _ in Issue.record("Duplicate send"); return .answered }
        continuation?.resume(returning: .answered)
        await task.value
        #expect(model.replyState(for: question) == .sent)
    }

    @Test("@spec WATCH-1.5: If a watch card is obsolete, cannot accept a text answer, or has a blank reply, then the application shall refuse to submit it.")
    func invalidRepliesNeverReachThePhone() async {
        let model = WatchInboxModel(snapshot: .init(cards: [card(occurrence: "new")], updatedAt: .now))
        let send: WatchInboxModel.Send = { _ in Issue.record("Invalid answer submitted"); return .answered }
        await model.answer(card(), text: "Ship", using: send)
        model.receive(.init(cards: [card(canReply: false)], updatedAt: .now))
        await model.answer(card(canReply: false), text: "Ship", using: send)
        model.receive(.init(cards: [card()], updatedAt: .now))
        await model.answer(card(), text: " \n", using: send)
    }

    @Test("@spec WATCH-1.6: If the host rejects a watch reply, then the application shall preserve the question and display the host's failure without marking the answer sent.")
    func rejectedAnswerKeepsTheQuestion() async {
        let question = card()
        let model = WatchInboxModel(snapshot: .init(cards: [question], updatedAt: .now))
        await model.answer(question, text: "Ship") { _ in .failure("This request has changed.") }
        #expect(model.snapshot.cards == [question])
        #expect(model.replyState(for: question) == .failed("This request has changed."))
    }

    @Test("@spec WATCH-1.7: When a newer watch inbox snapshot has arrived, the application shall ignore an older snapshot that finishes later.")
    func lateRefreshCannotRestoreAnOldQuestion() {
        let model = WatchInboxModel(snapshot: .init(cards: [card(occurrence: "new")], updatedAt: Date(timeIntervalSinceReferenceDate: 20)))
        model.receive(.init(cards: [card()], updatedAt: Date(timeIntervalSinceReferenceDate: 10)))
        #expect(model.snapshot.cards.first?.target?.occurrence == Data("new".utf8))
    }

    @Test("@spec WATCH-1.8: If an attention snapshot exceeds the watch transfer budget, then the application shall keep the newest cards within the budget and report the number of omitted requests.")
    func boundsPayloadWithoutSilentlyLosingRequests() throws {
        var cards = (0..<20).map { card(occurrence: String($0)) }
        for index in cards.indices { cards[index].context = String(repeating: "⌚", count: 500) }
        let snapshot = WatchAttentionSnapshot(cards: cards, updatedAt: .now)
        let bytes = try snapshot.encodedForTransfer(maximumBytes: 6_000)
        #expect(bytes.count <= 6_000)
        let decoded = try JSONDecoder().decode(WatchAttentionSnapshot.self, from: bytes)
        #expect(decoded.cards.count > 0)
        #expect(decoded.cards == Array(cards.prefix(decoded.cards.count)))
        #expect(decoded.cards.count + decoded.omittedCount == 20)
    }

    @Test("@spec WATCH-1.9: When a watch question is answered, the application shall use the same 60000-byte encoded request budget on both devices and report an oversized reply before sending it.")
    func displayedLargeCardsCanBeAnswered() throws {
        var question = card()
        question.context = String(repeating: "界", count: 7_000)
        let visible = try WatchAttentionSnapshot(cards: [question], updatedAt: .now).encodedForTransfer()
        #expect(visible.count < 48_000)
        let request = WatchRequest.answer(id: UUID(), card: question, text: "Ship")
        let data = try request.encodedForTransfer()
        #expect(data.count > 16_000)
        #expect(data.count <= WatchRequest.maximumBytes)
        question.context = String(repeating: "a", count: 61_000)
        #expect(throws: WatchRequest.TransferError.self) {
            try WatchRequest.answer(id: UUID(), card: question, text: "Ship").encodedForTransfer()
        }
    }
}
