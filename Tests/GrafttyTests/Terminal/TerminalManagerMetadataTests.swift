import Combine
import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("TerminalManager pane metadata")
struct TerminalManagerMetadataTests {

    @Test("""
@spec LAYOUT-2.19: When repeated terminal title or PWD actions leave a pane's rendered sidebar title unchanged, the application shall retain the latest raw metadata without publishing a sidebar invalidation.
""")
    func rawPWDUpdatesWithoutPublishingWhenRenderedTitleIsUnchanged() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = TerminalID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        var publishCount = 0
        let cancellable = manager.paneTitleInvalidations.objectWillChange.sink { publishCount += 1 }

        #expect(manager.recordPWD("/tmp/work", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "work")
        #expect(manager.pwds[terminalID] == "/tmp/work")
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        #expect(!manager.recordPWD("/var/work", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "work")
        #expect(manager.pwds[terminalID] == "/var/work")
        #expect(!manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        _ = cancellable
    }

    @Test("""
@spec LAYOUT-2.20: While a program-set pane title is the rendered sidebar title, incoming PWD actions shall update the raw pane PWD without publishing sidebar invalidations.
""")
    func pwdUpdatesUnderProgramTitleDoNotPublishSidebarTitleChanges() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = TerminalID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        var publishCount = 0
        let cancellable = manager.paneTitleInvalidations.objectWillChange.sink { publishCount += 1 }

        #expect(manager.recordTitle("claude", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "claude")
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        #expect(!manager.recordPWD("/tmp/work", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "claude")
        #expect(manager.pwds[terminalID] == "/tmp/work")
        #expect(!manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        _ = cancellable
    }

    @Test("""
@spec LAYOUT-2.21: When a terminal title action sanitizes to a rendered sidebar title equal to the current fallback title, the application shall store the raw title without publishing a sidebar invalidation.
""")
    func whitespaceTitleStoresWithoutPublishingWhenFallbackTitleIsUnchanged() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = TerminalID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        var publishCount = 0
        let cancellable = manager.paneTitleInvalidations.objectWillChange.sink { publishCount += 1 }

        #expect(manager.recordPWD("/tmp/work", for: terminalID))
        #expect(manager.displayTitle(for: terminalID) == "work")
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        #expect(!manager.recordTitle("   ", for: terminalID))
        #expect(manager.titles[terminalID] == "   ")
        #expect(manager.displayTitle(for: terminalID) == "work")
        #expect(!manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)

        _ = cancellable
    }

    @Test("""
@spec PERF-1.6: Pane title metadata changes shall not publish through TerminalManager itself, so title churn does not invalidate MainWindow observers.
""")
    func paneTitleChangesDoNotPublishTerminalManagerObjectWillChange() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = TerminalID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        var managerPublishCount = 0
        let cancellable = manager.objectWillChange.sink { managerPublishCount += 1 }

        #expect(manager.recordTitle("claude", for: terminalID))
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(managerPublishCount == 0)

        _ = cancellable
    }

    @Test("""
@spec PERF-1.7: Multiple rendered pane-title changes in one debounce window shall coalesce into one sidebar invalidation.
""")
    func paneTitleInvalidationsCoalesce() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        let terminalID = TerminalID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        var publishCount = 0
        let cancellable = manager.paneTitleInvalidations.objectWillChange.sink { publishCount += 1 }

        #expect(manager.recordTitle("one", for: terminalID))
        #expect(manager.recordTitle("two", for: terminalID))
        #expect(manager.recordTitle("three", for: terminalID))
        #expect(manager.paneTitleInvalidations.flushPendingForTests())
        #expect(publishCount == 1)
        #expect(manager.displayTitle(for: terminalID) == "three")

        _ = cancellable
    }
}
