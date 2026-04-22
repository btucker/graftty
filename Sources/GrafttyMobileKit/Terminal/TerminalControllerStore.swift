#if canImport(UIKit)
import GhosttyTerminal

/// A process-wide singleton wrapper around `TerminalController.shared`.
///
/// `TerminalController` already vends its own `shared` instance.  This
/// namespace exists so the rest of GrafttyMobileKit has a single, explicit
/// import point that can be swapped in tests or extended later.
@MainActor
public enum TerminalControllerStore {
    public static let shared: TerminalController = TerminalController.shared
}
#endif
