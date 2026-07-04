enum AppVisibilitySurfaceAction: Equatable {
    case setSelectedWorktreeVisible(path: String, visible: Bool)
}

enum AppVisibilitySurfacePolicy {
    static func action(
        selection: MainWindowSelection,
        selectedWorktreePath: String?,
        appIsVisible: Bool
    ) -> AppVisibilitySurfaceAction? {
        guard selection != .flowState else { return nil }
        guard let selectedWorktreePath else { return nil }
        return .setSelectedWorktreeVisible(
            path: selectedWorktreePath,
            visible: appIsVisible
        )
    }
}
