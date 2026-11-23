import AppKit

/// @spec GIT-4.19
/// Shared presenter for window-attached confirmation and startup sheets.
/// Centralises `NSAlert.beginSheetModal(for:)` so dialogs never block the
/// main run loop's default mode with `runModal()`, which would freeze
/// libghostty's PTY callbacks for embedded terminal panes while the dialog is
/// on screen. The `Configuration` and `HostWindowCandidate` value types stay
/// free of AppKit NIB loading so message-text, button-label, response-mapping,
/// and host-selection rules can be unit-tested without booting `NSApplication`.
enum SheetAlert {
    struct Configuration {
        var messageText: String
        var informativeText: String
        var style: NSAlert.Style
        var primaryButton: String
        var secondaryButton: String?
        var tertiaryButton: String? = nil
        var escapeButton: Response? = nil
    }

    enum Response: Equatable, Sendable {
        case primary
        case secondary
        case tertiary
        case cancelled
    }

    struct HostWindowCandidate: Equatable {
        let index: Int
        let isVisible: Bool
        let isPanel: Bool
        let isSheet: Bool
        let isChildWindow: Bool
        let canBecomeMain: Bool
        let isNormalLevel: Bool

        var isEligibleHost: Bool {
            isVisible && !isPanel && !isSheet && !isChildWindow && canBecomeMain && isNormalLevel
        }
    }

    private final class NotificationTokenBox: @unchecked Sendable {
        private let center: NotificationCenter
        private let tokens: [NSObjectProtocol]

        init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
            self.center = center
            self.tokens = tokens
        }

        func removeAll() {
            for token in tokens {
                center.removeObserver(token)
            }
        }
    }

    static func buttonTitles(for config: Configuration) -> [String] {
        precondition(
            config.secondaryButton != nil || config.tertiaryButton == nil,
            "SheetAlert.Configuration.tertiaryButton requires secondaryButton"
        )
        var titles = [config.primaryButton]
        if let secondary = config.secondaryButton {
            titles.append(secondary)
            if let tertiary = config.tertiaryButton {
                titles.append(tertiary)
            }
        }
        return titles
    }

    static func escapeButtonIndex(for config: Configuration) -> Int? {
        let titles = buttonTitles(for: config)
        switch config.escapeButton {
        case .primary:
            return 0
        case .secondary where titles.count > 1:
            return 1
        case .tertiary where titles.count > 2:
            return 2
        default:
            return nil
        }
    }

    static func response(for code: NSApplication.ModalResponse) -> Response {
        switch code {
        case .alertFirstButtonReturn:
            return .primary
        case .alertSecondButtonReturn:
            return .secondary
        case .alertThirdButtonReturn:
            return .tertiary
        default:
            return .cancelled
        }
    }

    static func selectReadyHostWindow(
        hasModalWindow: Bool,
        anyWindowHasAttachedSheet: Bool,
        mainWindow: HostWindowCandidate?,
        keyWindow: HostWindowCandidate?,
        windows: [HostWindowCandidate]
    ) -> Int? {
        guard !hasModalWindow, !anyWindowHasAttachedSheet else { return nil }
        if let preferred = [mainWindow, keyWindow].compactMap({ $0 }).first(where: \.isEligibleHost) {
            return preferred.index
        }
        return windows.first(where: \.isEligibleHost)?.index
    }

    /// Returns the preferred visible top-level host window when neither an
    /// app-modal dialog nor any window-attached sheet is currently active.
    @MainActor
    static func readyHostWindow() -> NSWindow? {
        guard let app = NSApp else { return nil }
        let windows = app.windows
        let candidates = windows.enumerated().map { index, window in
            HostWindowCandidate(
                index: index,
                isVisible: window.isVisible,
                isPanel: window is NSPanel,
                isSheet: window.sheetParent != nil,
                isChildWindow: window.parent != nil,
                canBecomeMain: window.canBecomeMain,
                isNormalLevel: window.level == .normal
            )
        }
        let mainCandidate = app.mainWindow
            .flatMap { main in windows.firstIndex(where: { $0 === main }) }
            .map { candidates[$0] }
        let keyCandidate = app.keyWindow
            .flatMap { key in windows.firstIndex(where: { $0 === key }) }
            .map { candidates[$0] }
        guard let selectedIndex = selectReadyHostWindow(
            hasModalWindow: app.modalWindow != nil,
            anyWindowHasAttachedSheet: windows.contains(where: { $0.attachedSheet != nil }),
            mainWindow: mainCandidate,
            keyWindow: keyCandidate,
            windows: candidates
        ) else {
            return nil
        }
        return windows[selectedIndex]
    }

    /// Waits for a ready host window without unbounded periodic polling.
    /// Returns immediately if one is already available; otherwise observes
    /// window/sheet/activation lifecycle notifications (plus one short launch
    /// grace check) until a host window is ready or the task is cancelled.
    @MainActor
    static func awaitReadyHostWindow(
        initialGraceDelay: Duration = .milliseconds(500),
        center: NotificationCenter = .default,
        readyWindow: @escaping @MainActor () -> NSWindow? = readyHostWindow
    ) async -> NSWindow? {
        if let window = readyWindow() {
            return window
        }
        guard !Task.isCancelled else { return nil }

        let stream = AsyncStream<Void> { continuation in
            let names: [Notification.Name] = [
                NSWindow.didBecomeMainNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didEndSheetNotification,
                NSWindow.willCloseNotification,
                NSApplication.didBecomeActiveNotification,
            ]
            let tokens = names.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    DispatchQueue.main.async {
                        continuation.yield(())
                    }
                }
            }
            let tokenBox = NotificationTokenBox(center: center, tokens: tokens)
            let graceTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: initialGraceDelay)
                } catch {
                    return
                }
                continuation.yield(())
            }
            continuation.onTermination = { _ in
                graceTask.cancel()
                tokenBox.removeAll()
            }
        }

        for await _ in stream {
            if Task.isCancelled { return nil }
            if let window = readyWindow() {
                return window
            }
        }
        return nil
    }

    /// Presents `config` as a sheet on `window`. Caller owns the
    /// host-window guard — typically `guard let host = NSApp.mainWindow
    /// else { return }`. For a single-button
    /// alert (`secondaryButton == nil`), the completion fires with
    /// `.primary` on the lone "OK" click, or `.cancelled` if aborted.
    @MainActor
    static func present(
        _ config: Configuration,
        on window: NSWindow,
        completion: @escaping @MainActor (Response) -> Void = { _ in }
    ) {
        let alert = NSAlert()
        alert.messageText = config.messageText
        alert.informativeText = config.informativeText
        alert.alertStyle = config.style
        for title in buttonTitles(for: config) {
            alert.addButton(withTitle: title)
        }
        if let escapeIndex = escapeButtonIndex(for: config),
           alert.buttons.indices.contains(escapeIndex) {
            alert.buttons[escapeIndex].keyEquivalent = "\u{1b}"
        }
        alert.beginSheetModal(for: window) { code in
            MainActor.assumeIsolated {
                completion(response(for: code))
            }
        }
    }

    @discardableResult
    @MainActor
    static func presentAsync(
        _ config: Configuration,
        on window: NSWindow
    ) async -> Response {
        await withCheckedContinuation { continuation in
            present(config, on: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
