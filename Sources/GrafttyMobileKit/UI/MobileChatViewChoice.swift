import Foundation

/// The iPhone's Chat or Terminal choice for each agent tab. iPad keeps its
/// choice in the workspace layout. Both stay on this device.
enum MobileChatViewChoice {
    static func key(hostID: UUID, worktreePath: String, sessionName: String) -> String {
        "workspace.iphone.chat.\(hostID).\(worktreePath).\(sessionName)"
    }

    static func showsChat(
        hostID: UUID, worktreePath: String, sessionName: String, defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key(hostID: hostID, worktreePath: worktreePath, sessionName: sessionName))
    }

    static func setShowsChat(
        _ value: Bool, hostID: UUID, worktreePath: String, sessionName: String, defaults: UserDefaults = .standard
    ) {
        let key = key(hostID: hostID, worktreePath: worktreePath, sessionName: sessionName)
        if value { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
