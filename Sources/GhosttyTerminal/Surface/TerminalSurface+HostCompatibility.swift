import GhosttyKit

extension TerminalSurface {
    @discardableResult
    public func sendLeftMouseDown() -> Bool {
        sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    @discardableResult
    public func sendLeftMouseUp() -> Bool {
        sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    @discardableResult
    public func performAction(_ action: String) -> Bool {
        performBindingAction(action)
    }
}
