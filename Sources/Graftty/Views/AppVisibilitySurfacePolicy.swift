enum AppVisibilitySurfaceAction: Equatable {
    case setSelectedWorktreeVisible(path: String, visible: Bool)
}

enum AppVisibilitySurfacePolicy {
    static func action(
        selectedWorktreePath: String?,
        appIsVisible: Bool
    ) -> AppVisibilitySurfaceAction? {
        guard let selectedWorktreePath else { return nil }
        return .setSelectedWorktreeVisible(
            path: selectedWorktreePath,
            visible: appIsVisible
        )
    }
}
