import Testing
@testable import GrafttyKit

@Suite struct PaneAddressTests {
    @Test func emptyArgYieldsCurrentWorktreeAndNoID() throws {
        #expect(PaneAddress.parse(nil) == .currentWorktreeAnyPane)
        #expect(PaneAddress.parse("") == .currentWorktreeAnyPane)
    }

    @Test func numericArgYieldsCurrentWorktreeWithID() throws {
        #expect(PaneAddress.parse("3") == .currentWorktreeID(3))
    }

    @Test func nonNumericArgYieldsNamedWorktreeAnyPane() throws {
        #expect(PaneAddress.parse("drag-files") == .namedWorktreeAnyPane("drag-files"))
    }

    @Test func nameAndIDYieldsNamedWorktreeWithID() throws {
        #expect(PaneAddress.parse("drag-files:2") == .namedWorktreeID("drag-files", 2))
    }

    @Test func emptyNameOrIDIsInvalid() throws {
        #expect(PaneAddress.parse(":3") == .invalid(":3"))
        #expect(PaneAddress.parse("drag-files:") == .invalid("drag-files:"))
    }

    @Test func nonNumericIDIsInvalid() throws {
        #expect(PaneAddress.parse("drag-files:abc") == .invalid("drag-files:abc"))
    }

    @Test func multipleColonsInvalid() throws {
        #expect(PaneAddress.parse("a:b:1") == .invalid("a:b:1"))
    }

    @Test func absolutePathMayContainColons() {
        let path = "/tmp/Project: Next/.worktrees/fix"
        #expect(PaneAddress.parse(path) == .namedWorktreeAnyPane(path))
        #expect(PaneAddress.parse(path + ":2") == .namedWorktreeID(path, 2))
    }

    @Test func zeroOrNegativeIDIsInvalid() throws {
        #expect(PaneAddress.parse("0") == .invalid("0"))
        #expect(PaneAddress.parse("-1") == .invalid("-1"))
        #expect(PaneAddress.parse("drag-files:0") == .invalid("drag-files:0"))
    }
}
