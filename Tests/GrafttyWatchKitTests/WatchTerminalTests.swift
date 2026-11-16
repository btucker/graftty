import Foundation
import Testing
@testable import GrafttyWatchKit

@MainActor
struct WatchTerminalTests {
    let target = WatchTerminalTarget(hostID: UUID(), worktreeID: "/watch", paneID: "agent", project: "Graftty", worktree: "watch", host: "Mac", title: "Codex")

    @Test("@spec WATCH-3.3: When a watch terminal refresh succeeds, the application shall display the returned output for the selected pane and retain it with an error if a later refresh fails.")
    func refreshKeepsRealOutputOnFailure() async {
        let model = WatchTerminalModel(target: target)
        await model.refresh { request in
            #expect(request == .terminal(target))
            return .terminal(.init(targetID: target.id, text: "$ make\n  done\n$ "))
        }
        #expect(model.frame?.text == "$ make\n  done\n$ ")
        await model.refresh { _ in .failure("Host offline") }
        #expect(model.frame?.text == "$ make\n  done\n$ ")
        #expect(model.error == "Host offline")
        #expect(!model.isLoading)
    }

    @Test("@spec WATCH-3.4: While a watch terminal read is pending, the application shall prevent overlapping reads and ignore its result after the terminal view stops or the returned pane does not match.")
    func stopDiscardsInFlightOutput() async {
        let model = WatchTerminalModel(target: target)
        var pending: CheckedContinuation<WatchResponse, Error>?
        var finished = false
        let task = Task {
            defer { finished = true }
            await model.refresh { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        }
        while pending == nil, !finished { await Task.yield() }
        guard let pending else { Issue.record("No terminal read was requested"); return }
        #expect(model.isLoading)
        await model.refresh { _ in Issue.record("Overlapping read"); return .failure("Unexpected") }
        model.stop()
        pending.resume(returning: .terminal(.init(targetID: target.id, text: "old")))
        await task.value
        #expect(model.frame == nil)
        #expect(!model.isLoading)
        await model.refresh { _ in .terminal(.init(targetID: "another pane", text: "wrong")) }
        #expect(model.frame == nil)
        #expect(model.error != nil)
    }

    @Test func terminalWireRoundTrips() throws {
        let request = WatchRequest.terminal(target)
        #expect(try JSONDecoder().decode(WatchRequest.self, from: JSONEncoder().encode(request)) == request)
        let response = WatchResponse.terminal(.init(targetID: target.id, text: "界\n$ "))
        #expect(try JSONDecoder().decode(WatchResponse.self, from: JSONEncoder().encode(response)) == response)
    }
}
