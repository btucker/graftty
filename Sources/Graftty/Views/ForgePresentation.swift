import GrafttyKit

/// Maps a repo's hosting origin to its context-menu presentation —
/// the user-facing forge name behind "Open on GitHub…/GitLab…". nil
/// for unsupported providers and absent origins, which get no forge
/// menu item at all (PROJECT-2.2).
struct ForgePresentation: Equatable {
    let forgeName: String

    init?(origin: HostingOrigin?) {
        switch origin?.provider {
        case .github:
            forgeName = "GitHub"
        case .gitlab:
            forgeName = "GitLab"
        case .unsupported, nil:
            return nil
        }
    }

    var menuTitle: String { "Open on \(forgeName)…" }
}
