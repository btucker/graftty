import AppKit
import GrafttyKit

/// Per-provider one-shot nudge presented when the user adds a repo whose
/// origin's host CLI is missing from PATH. Without it, Graftty's PR/MR
/// column stays mysteriously empty for the new repo.
@MainActor
enum HostCLIInstallNudge {

    private static var shownThisProcess: Set<HostingProvider> = []

    static func suppressionKey(for provider: HostingProvider) -> String {
        "hostCLIInstallNudge.suppress.\(provider.rawValue)"
    }

    static func presentIfNeeded(
        for provider: HostingProvider,
        availability: @Sendable (String) async -> Bool = { command in
            await HostCLIAvailability.isAvailable(command: command)
        }
    ) async {
        guard !shownThisProcess.contains(provider) else { return }
        guard !UserDefaults.standard.bool(forKey: suppressionKey(for: provider)) else { return }
        guard let meta = HostCLIAvailability.metadata(for: provider) else { return }

        let installed = await availability(meta.cli)
        guard !installed else { return }

        shownThisProcess.insert(provider)
        present(provider: provider, meta: meta)
    }

    private static func present(provider: HostingProvider, meta: HostCLIAvailability.Metadata) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install \(meta.cli) to see PR status"
        alert.informativeText = """
            Graftty uses the `\(meta.cli)` command-line tool to fetch \
            \(meta.prTerm) status for repositories on \(meta.displayName). \
            Without it, the sidebar won't show PR badges or CI status for \
            this repository.

            Install with Homebrew:
                \(meta.brewCommand)
            """

        alert.addButton(withTitle: "Open Install Page")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Show Again")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(meta.installURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: suppressionKey(for: provider))
        default:
            break
        }
    }

    static func resetForTests() {
        shownThisProcess.removeAll()
    }
}
