import Foundation
import GrafttyProtocol

public enum TerminalTextDelivery {
    @MainActor
    public static func read(worktreeID: String, paneID: String, lines: Int,
                            platform: any ControlPlatform) async -> WorktreeManagementResponse {
        guard let worktree = platform.state.worktree(forPath: worktreeID), worktree.state == .running,
              let slot = worktree.paneSlot(forSessionName: paneID),
              let index = worktree.splitTree.allLeaves.firstIndex(of: slot) else {
            return .error(code: "terminal-unavailable", message: "This terminal is no longer running. Refresh the watch's terminal list.", forceAllowed: false, shortStatus: nil)
        }
        let response = await platform.handlePlatformRequest(.showPane(path: worktreeID, index: index + 1, lines: min(200, max(1, lines))))
        switch response {
        case .paneShow(let text):
            let bytes = text.utf8.suffix(24_000)
            var start = bytes.startIndex
            while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 { start = bytes.index(after: start) }
            return .terminalText(String(decoding: bytes[start...], as: UTF8.self))
        case .error(let message):
            return .error(code: "terminal-read-failed", message: message, forceAllowed: false, shortStatus: nil)
        default:
            return .error(code: "terminal-read-failed", message: "The host couldn't read this terminal.", forceAllowed: false, shortStatus: nil)
        }
    }
}
