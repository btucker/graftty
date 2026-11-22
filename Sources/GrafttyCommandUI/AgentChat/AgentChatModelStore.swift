import GrafttyProtocol

/// Keeps one Chat model per agent tab for as long as its owner lives, so a
/// draft is still there when the viewer returns from Terminal.
@MainActor
public final class AgentChatModelStore<Tab: Hashable> {
    private var models: [Tab: AgentChatModel] = [:]

    public init() {}

    public func model(for tab: Tab) -> AgentChatModel {
        if let model = models[tab] { return model }
        let model = AgentChatModel()
        models[tab] = model
        return model
    }

    /// Drops the models of tabs that no longer exist.
    public func prune(keeping tabs: Set<Tab>) {
        models = models.filter { tabs.contains($0.key) }
    }
}
