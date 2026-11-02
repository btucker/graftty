import Foundation
import GrafttyKit

@MainActor
enum ImagePreviewRequest {
    static func handle(path: String, target: String, paneSessionName: String?,
                       state: () -> AppState, terminalManager: TerminalManager, store: RemoteOpenStore = .shared) async -> ResponseMessage {
        await FilePreviewRequest.handle(path: path, targets: [target], paneSessionName: paneSessionName,
                                        state: state, terminalManager: terminalManager, store: store)
    }
}
