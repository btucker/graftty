import Foundation
import Testing
@testable import GrafttyProtocol

struct WorktreeHistoryTests {
    private let start = Date(timeIntervalSince1970: 100)

    @Test("@spec CONTEXT-22: When Context history displays a source worktree, the application shall label it with its directory name while retaining its full path for navigation and sender details.")
    func worktreeLabelsUseNames() {
        var history = WorktreeHistory()
        history.record(.init(text: "<graftty-peer-message agent=\"/Users/example/repo/.worktrees/fix layout#codex-123\">Checked.</graftty-peer-message>", at: start))
        let event = WorktreeTimeline(history: history, brief: nil).events.first
        #expect(event?.sourceWorktreeName == "fix layout")
        #expect(event?.sourceWorktreePath == "/Users/example/repo/.worktrees/fix layout")
        #expect(event?.title.contains("#codex-123") == true)
    }

    @Test("@spec CONTEXT-20: When Context history identifies a peer by an absolute worktree address, the application shall expose its worktree path separately from its agent suffix for in-app navigation, while leaving unnamed peers and non-path sender labels unlinked.")
    func peerAddressesExposeWorktreePaths() {
        var history = WorktreeHistory()
        for sender in ["/repo/R&amp;D#codex-abcdef012345", "/repo/with spaces#claude", "/repo/hash#name#claude-abcdef", "/repo/literal#name", "Graftty bridge", "uds:/tmp/peer.sock"] {
            history.record(.init(text: "<graftty-peer-message agent=\"\(sender)\">A report.</graftty-peer-message>", at: start))
        }
        history.record(.init(text: "<graftty-peer-message>A report.</graftty-peer-message>", at: start))
        let events = WorktreeTimeline(history: history, brief: nil).events
        #expect(events.map(\.sourceWorktreePath) == ["/repo/R&D", "/repo/with spaces", "/repo/hash#name", "/repo/literal#name", nil, nil, nil])
        #expect(events.first?.title == "Message from /repo/R&D#codex-abcdef012345")
    }

    @Test("@spec CONTEXT-18: When provider prompt history contains human text, peer envelopes, or generated system, forge, and hook context, the application shall highlight only human text as user input, retain peer content with its available sender provenance, and exclude generated context, including in restored history and mixed Codex and Claude turns.")
    func providerUserRolesDoNotEstablishHumanAuthorship() throws {
        // Codex turn/start and Claude's native peer transport both use user
        // roles. These text shapes come from the delivery formatter and the
        // fake-backend provider fixtures, not an authorship guarantee.
        let peer = """
        <graftty-peer-message agent="/repo/R&amp;D#codex-abcdef012345" id="42">
        Please verify the fix.
        </graftty-peer-message>
        """
        let claude = """
        Another Claude session sent a message:
        <cross-session-message from="uds:/tmp/peer.sock" from-name="Graftty bridge">
        \(peer)
        </cross-session-message>
        """
        var history = WorktreeHistory()
        let prompts = ["Fix the bug.", peer, claude, """
            Keep the regression test.

            \(peer)

            <graftty-system-message>Startup context</graftty-system-message>
            <graftty-forge-message provider="github">CI passed</graftty-forge-message>
            <system-reminder>Hook context</system-reminder>

            Also check iPad.
            """]
        for (offset, text) in prompts.enumerated() {
            history.record(.init(text: text, at: start.addingTimeInterval(Double(offset))))
        }
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history))
        let events = WorktreeTimeline(history: restored, brief: nil).events
        #expect(events.filter { $0.kind == .user }.map(\.completed) == ["Fix the bug.", "Keep the regression test.", "Also check iPad."])
        let peers = events.filter { $0.title.contains("/repo/R&D#codex-abcdef012345") }
        #expect(peers.count == 3)
        #expect(peers.allSatisfy { $0.kind != .user && $0.completed == "Please verify the fix." })
        #expect(!events.contains { $0.completed.contains("Startup context") || $0.completed.contains("CI passed") || $0.completed.contains("Hook context") })
        #expect(Set(events.map(\.id)).count == events.count)
        // Old saved history has no source field and stores the provider frame.
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var inputs = try #require(legacy["inputs"] as? [[String: Any]])
        for index in inputs.indices {
            inputs[index].removeValue(forKey: "source")
            inputs[index]["text"] = prompts[index]
        }
        legacy["inputs"] = inputs
        let old = try JSONDecoder().decode(WorktreeHistory.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(WorktreeTimeline(history: old, brief: nil).events == events)
    }

    @Test func provenanceSurvivesTruncationAndProviderContextStaysGenerated() throws {
        let body = String(repeating: "Peer task. ", count: 500)
        let prompt = "<cross-session-message from-name=\"Graftty bridge\">\n"
            + "<graftty-peer-message agent=\"/parent#claude\">" + body
            + "</graftty-peer-message>\n</cross-session-message>"
        var history = WorktreeHistory()
        history.record(.init(text: prompt, at: start))
        history.record(.init(text: "<environment_context>Generated Codex environment</environment_context>", at: start))
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history))
        let events = WorktreeTimeline(history: restored, brief: nil).events
        #expect(events.count == 1)
        #expect(events.first?.kind == .agentMessage)
        #expect(events.first?.title == "Message from /parent#claude")
        #expect(events.first?.completed == String(body.prefix(2000)) + "…")
        #expect(restored.inputs[0].wasTruncated)
    }

    @Test func literalEnvelopeMentionsRemainHumanText() {
        let texts = ["Keep <graftty-peer-message> out of my history.", """
            Explain this example:
            ```xml
            <graftty-peer-message agent="example">quoted content</graftty-peer-message>
            ```
            """, "Please mention Another Claude session sent a message: in the docs."]
        for text in texts {
            var history = WorktreeHistory()
            history.record(.init(text: text, at: start))
            let events = WorktreeTimeline(history: history, brief: nil).events
            #expect(events.count == 1)
            #expect(events.first?.kind == .user)
            #expect(events.first?.completed == text)
        }
    }

    @Test func generatedPrefixesDoNotCrowdOutMixedConversationInput() {
        let prompt = "<system-reminder>" + String(repeating: "generated ", count: 300)
            + "</system-reminder>\nKeep my request.\n"
            + "<graftty-peer-message agent=\"/parent#codex\">Keep the peer context.</graftty-peer-message>"
        var history = WorktreeHistory()
        history.record(.init(text: prompt, at: start))
        let events = WorktreeTimeline(history: history, brief: nil).events
        #expect(events.map(\.completed) == ["Keep my request.", "Keep the peer context."])
        #expect(events.map(\.kind) == [.user, .agentMessage])
    }

    @Test func literalClosingTagsInNativePeerBodiesCannotBecomeHumanInput() {
        let body = "Please examine </graftty-peer-message> & keep <literal> context."
        let prompt = "<cross-session-message from-name=\"Native peer\">\(body)</cross-session-message>\nKeep my request."
        var history = WorktreeHistory()
        history.record(.init(text: prompt, at: start))
        let events = WorktreeTimeline(history: history, brief: nil).events
        #expect(events.map(\.kind) == [.agentMessage, .user])
        #expect(events.map(\.completed) == [body, "Keep my request."])
    }

    @Test("@spec CONTEXT-12: When a worktree creation is recorded, the application shall retain its timestamp and distinguish human UI creation from creation in another worktree, without inferring an unknown creator from the Git base branch.")
    func creationIsFirstAndUnknownOriginsStayUnknown() throws {
        let origin = WorktreeHistory.Origin(date: start, source: .worktree, worktreePath: "/repo/main", worktreeName: "main")
        let history = WorktreeHistory(origin: origin)
        let timeline = WorktreeTimeline(history: history, brief: brief(count: 2))
        #expect(timeline.events.first?.kind == .creation)
        #expect(timeline.events.first?.title == "Created from main")
        #expect(timeline.events.first?.sourceWorktreePath == "/repo/main")
        #expect(timeline.events.first?.timestamp == start.timeIntervalSinceReferenceDate)
        let user = WorktreeTimeline(history: .init(origin: .init(date: start, source: .user)), brief: nil)
        #expect(user.events.first?.title == "Created by you")
        let unknown = WorktreeTimeline(history: .init(origin: .init(date: start, source: .unknown)), brief: nil)
        #expect(unknown.events.first?.title == "Worktree created")
        #expect(unknown.events.first?.sourceWorktreePath == nil)
        #expect(WorktreeTimeline(history: nil, brief: nil).events.isEmpty)
        #expect(try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history)) == history)
    }

    @Test("@spec CONTEXT-14: While a worktree history has more than eight events, the application shall fold only consecutive runs of at least two older legacy checkpoints, retain creation, every user input, and the latest two checkpoints, and expand each run or all events in chronological order.")
    func foldsOnlyOlderAgentRuns() throws {
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        let input = WorktreeHistory.UserInput(text: "yes", at: start.addingTimeInterval(35))
        history.record(input)
        history.record(input) // Replaying a handoff must not duplicate the reply.
        let timeline = WorktreeTimeline(history: history, brief: brief(count: 10))
        #expect(timeline.events.count == 12)
        #expect(timeline.events.filter { $0.kind == .user }.count == 1)
        let eventTimestamps: [Double?] = timeline.events.filter { $0.kind != .creation }.map(\.timestamp)
        let sortedTimestamps = eventTimestamps.sorted { ($0 ?? 0) < ($1 ?? 0) }
        #expect(eventTimestamps == sortedTimestamps)
        let rows = timeline.rows(showAll: false)
        #expect(rows.map(\.events.count) == [1, 4, 1, 4, 1, 1])
        #expect(rows.filter(\.isGroup).allSatisfy { $0.events.allSatisfy { $0.kind == .checkpoint } })
        #expect(rows.flatMap(\.events) == timeline.events)
        #expect(timeline.rows(showAll: true).count == timeline.events.count)
        #expect(rows.suffix(2).allSatisfy { !$0.isGroup })
        let short = WorktreeTimeline(history: history, brief: brief(count: 3))
        #expect(short.rows(showAll: false).allSatisfy { !$0.isGroup })
        #expect(try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history)) == history)
    }

    @Test("@spec CONTEXT-25: When a worktree history contains consecutive peer messages from one sender or human inputs at most ten minutes apart, the application shall merge each run into one peer-message or input row in chronological order, collapsing consecutive exact-duplicate peer messages into one entry with a repeat count, whether or not all steps are shown.")
    func mergesPeerRunsAndNearbyInputs() {
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        func peer(_ sender: String, _ text: String, _ offset: Double) {
            history.record(.init(text: "<graftty-peer-message agent=\"\(sender)#claude\">\(text)</graftty-peer-message>", at: start.addingTimeInterval(offset)))
        }
        history.record(.init(text: "First", at: start.addingTimeInterval(10)))
        history.record(.init(text: "Second", at: start.addingTimeInterval(610)))
        history.record(.init(text: "Much later", at: start.addingTimeInterval(1211)))
        peer("/repo/a", "Started.", 1300)
        peer("/repo/a", "Still waiting.", 1310)
        peer("/repo/a", "Still waiting.", 1320)
        peer("/repo/a", "Done.", 1330)
        peer("/repo/a", "Still waiting.", 1340)
        peer("/repo/b", "Other sender.", 1350)
        history.record(.init(text: "Thanks", at: start.addingTimeInterval(1360)))
        peer("/repo/a", "After your reply.", 1370)
        let timeline = WorktreeTimeline(history: history, brief: brief(count: 2))
        for showAll in [false, true] {
            let rows = timeline.rows(showAll: showAll)
            #expect(rows.map(\.kind) == [.event, .event, .event, .inputs, .inputs, .peerMessages, .peerMessages, .inputs, .peerMessages])
            #expect(rows.map(\.events.count) == [1, 1, 1, 2, 1, 5, 1, 1, 1])
            #expect(rows.flatMap(\.events) == timeline.events)
            #expect(!rows.contains { $0.isGroup })
            let peers = rows[5].entries
            #expect(peers.map(\.event.completed) == ["Started.", "Still waiting.", "Done.", "Still waiting."])
            #expect(peers.map(\.count) == [1, 2, 1, 1])
            #expect(rows[3].entries.map(\.event.completed) == ["First", "Second"])
        }
        var unnamed = WorktreeHistory()
        for offset in 0..<2 {
            unnamed.record(.init(text: "<graftty-peer-message>Report \(offset)</graftty-peer-message>", at: start.addingTimeInterval(Double(offset))))
        }
        #expect(WorktreeTimeline(history: unnamed, brief: nil).rows(showAll: false).map(\.events.count) == [2])
    }

    @Test("@spec CONTEXT-24: When a history contains explicit entries and legacy snapshots, the application shall keep explicit headlines visible in the shared timeline and show only decisions newly introduced relative to the previous legacy snapshot.")
    func explicitHeadlinesStayVisibleAndLegacyDecisionsDoNotRepeat() throws {
        var brief = brief(count: 10)
        for index in 0..<10 {
            let data = try JSONSerialization.data(withJSONObject: ["title": "Context", "completed": "Routine status", "next": "Review", "historyEntry": ["headline": "Discovery \(index)"]])
            brief.update(try JSONDecoder().decode(AttentionRecap.self, from: data), at: start.addingTimeInterval(Double(200 + index)))
        }
        let timeline = WorktreeTimeline(history: nil, brief: brief)
        let explicit = timeline.rows(showAll: false).filter { $0.events.contains { $0.title.hasPrefix("Discovery") } }
        #expect(explicit.count == 10)
        #expect(explicit.allSatisfy { !$0.isGroup && $0.events[0].completed.isEmpty })

        // Restore snapshots written before explicit history entries existed.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(brief)) as? [String: Any])
        var snapshots = try #require(object["history"] as? [[String: Any]])
        snapshots = Array(snapshots.prefix(3))
        snapshots[0]["decisions"] = ["Keep source text"]
        snapshots[1]["decisions"] = ["Keep source text", "Generate on host"]
        snapshots[2]["decisions"] = ["Generate on host"]
        object["history"] = snapshots
        let restored = try JSONDecoder().decode(WorktreeBrief.self, from: JSONSerialization.data(withJSONObject: object))
        let events = WorktreeTimeline(history: nil, brief: restored).events
        #expect(events.map(\.decisions) == [["Keep source text"], ["Generate on host"], []])
        #expect(restored.history[1].decisions == ["Keep source text", "Generate on host"], "Projection must preserve the saved source")
    }

    @Test func inputRemainsChronologicalAndBounded() {
        var history = WorktreeHistory()
        let late = WorktreeHistory.UserInput(text: "Later", at: start.addingTimeInterval(10))
        history.record(late)
        history.record(.init(text: "Earlier", at: start))
        #expect(history.inputs.map(\.text) == ["Earlier", "Later"])
        let long = WorktreeHistory.UserInput(text: String(repeating: "x", count: 5000), at: start)
        #expect(long.text.count == 2000)
        #expect(long.wasTruncated)
        let emoji = WorktreeHistory.UserInput(text: String(repeating: "👨‍👩‍👧‍👦", count: 2000), at: start)
        #expect(emoji.text.utf8.count <= 8000)
        #expect(emoji.wasTruncated)
        #expect(!emoji.text.contains("�"))
    }

    @Test func userInputSeparatesRepeatedCheckpointHeadings() {
        var brief = brief(count: 1)
        brief.update(.init(title: "Context", completed: "After your reply", next: "Verify", checkpoint: "Step 0"),
            at: start.addingTimeInterval(20), preservingCheckpointBefore: start.addingTimeInterval(10))
        #expect(brief.history.count == 2)
        #expect(brief.history.first?.completed == "Progress 0")
    }

    private func brief(count: Int) -> WorktreeBrief {
        var value = WorktreeBrief(recap: .init(title: "Context", completed: "Progress 0", next: "Next", checkpoint: "Step 0"), at: start)
        for index in 1..<count {
            value.update(.init(title: "Context", completed: "Progress \(index)", next: "Next", checkpoint: "Step \(index)"), at: start.addingTimeInterval(Double(index * 10)))
        }
        return value
    }
}
