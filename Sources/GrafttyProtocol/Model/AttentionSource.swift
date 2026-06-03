/// Where an attention overlay came from. Lives in `GrafttyProtocol` so both
/// the model (`GrafttyKit.Attention`) and the `PaneLayoutNode` wire model can
/// reference one definition — the iPad/web surface needs the source to know
/// whether a capsule is the agent "needs input" state (rendered as an icon)
/// versus a `graftty notify` ping or a ✓/! marker (rendered as text).
public enum AttentionSource: String, Codable, Sendable, Equatable {
    case agentStop        // "<Agent> needs input" from a Stop hook
    case userNotify       // `graftty notify` — a deliberate user ping
    case commandFinished  // ✓ / ! shell-integration COMMAND_FINISHED
}

/// How a pane/worktree attention capsule should render. The agent "needs
/// input" state shows an SF Symbol; everything else shows its text. The
/// `label` on `.needsInput` preserves the human text ("Claude needs input")
/// for accessibility / tooltip even though the visual is an icon.
public enum AttentionCapsuleStyle: Equatable, Sendable {
    case needsInput(label: String)
    case text(String)

    /// SF Symbol name for the agent "needs input" capsule.
    public static let needsInputSymbol = "rectangle.and.pencil.and.ellipsis"

    public static func from(text: String, source: AttentionSource?) -> AttentionCapsuleStyle {
        source == .agentStop ? .needsInput(label: text) : .text(text)
    }
}
