import Foundation
import Testing
@testable import GrafttyKit

@Suite("PushDedupeStore")
struct PushDedupeStoreTests {
    @Test func returnsNilForUnknownWorktree() {
        let s = PushDedupeStore()
        #expect(s.lastPushed(forWorktree: "/x") == nil)
    }

    @Test func markPushedRecordsTimestamp() {
        let s = PushDedupeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        s.markPushed(worktree: "/x", attentionTimestamp: t)
        #expect(s.lastPushed(forWorktree: "/x") == t)
    }

    @Test func separateWorktreesAreIndependent() {
        let s = PushDedupeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        s.markPushed(worktree: "/a", attentionTimestamp: t)
        #expect(s.lastPushed(forWorktree: "/b") == nil)
    }
}
