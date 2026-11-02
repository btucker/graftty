import AppKit

/// Provides the application termination boundary for asynchronous Web Access
/// shutdown. The reply is injectable so tests never terminate their process.
@MainActor
final class WebAccessTerminationDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (@MainActor () async -> Void)?
    private let reply: @MainActor (NSApplication, Bool) -> Void
    private var terminationTask: Task<Void, Never>?

    override convenience init() {
        self.init(reply: { $0.reply(toApplicationShouldTerminate: $1) })
    }

    init(reply: @escaping @MainActor (NSApplication, Bool) -> Void) {
        self.reply = reply
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task {
                await shutdown()
                reply(sender, true)
            }
        }
        return .terminateLater
    }
}
