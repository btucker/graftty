import SwiftUI
import AppKit

/// Attach to a view to restore and track its window's frame.
///
/// On first attach to a window, applies `initialFrame` to the window — unless
/// that frame is off-screen, in which case the OS's automatic window placement
/// is used instead (avoids the classic "my saved position points to a monitor I
/// no longer have plugged in" bug).
///
/// After attach, subscribes to `didResize` and `didMove` notifications and
/// reports frame changes via `onFrameChange`, debounced so rapid drags don't
/// generate a flood of writes.
struct WindowFrameTracker: NSViewRepresentable {
    let initialFrame: CGRect?
    let debounceInterval: TimeInterval
    let onFrameChange: (CGRect) -> Void

    init(
        initialFrame: CGRect? = nil,
        debounceInterval: TimeInterval = 0.25,
        onFrameChange: @escaping (CGRect) -> Void
    ) {
        self.initialFrame = initialFrame
        self.debounceInterval = debounceInterval
        self.onFrameChange = onFrameChange
    }

    func makeNSView(context: Context) -> NSView {
        let view = TrackerNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initialFrame: initialFrame,
            onFrameChange: onFrameChange,
            debounceInterval: debounceInterval
        )
    }

    @MainActor
    final class Coordinator {
        var initialFrame: CGRect?
        private let onFrameChange: (CGRect) -> Void
        private let debounceInterval: TimeInterval
        private var observers: [NSObjectProtocol] = []
        private var pendingTask: Task<Void, Never>?
        private weak var window: NSWindow?
        private var didApplyInitialFrame = false

        init(
            initialFrame: CGRect?,
            onFrameChange: @escaping (CGRect) -> Void,
            debounceInterval: TimeInterval
        ) {
            self.initialFrame = initialFrame
            self.onFrameChange = onFrameChange
            self.debounceInterval = debounceInterval
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window

            applyInitialFrameIfNeeded(to: window)

            let nc = NotificationCenter.default
            let resize = nc.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFrameChange() }
            }
            let move = nc.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFrameChange() }
            }
            observers = [resize, move]
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            pendingTask?.cancel()
            pendingTask = nil
            window = nil
        }

        private func applyInitialFrameIfNeeded(to window: NSWindow) {
            guard !didApplyInitialFrame, let frame = initialFrame else { return }
            didApplyInitialFrame = true
            guard Self.frameIsVisibleOnAnyScreen(frame) else {
                // Saved frame is on a monitor that's no longer attached.
                // Leave the window where SwiftUI/NSWindowRestoration put it.
                return
            }
            window.setFrame(frame, display: true)
        }

        /// A frame is "visible" if it overlaps any connected screen's visible
        /// frame by at least 40pt in each dimension — enough to see the
        /// title bar and grab it.
        static func frameIsVisibleOnAnyScreen(_ frame: CGRect) -> Bool {
            let minOverlap: CGFloat = 40
            for screen in NSScreen.screens {
                let intersection = screen.visibleFrame.intersection(frame)
                if intersection.width >= minOverlap && intersection.height >= minOverlap {
                    return true
                }
            }
            return false
        }

        private func scheduleFrameChange() {
            pendingTask?.cancel()
            guard let window else { return }
            let frame = window.frame
            pendingTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.debounceInterval))
                if Task.isCancelled { return }
                self.onFrameChange(frame)
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    private final class TrackerNSView: NSView {
        var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                coordinator?.attach(to: window)
            }
        }
    }
}

extension View {
    /// Restore and observe the host window's frame. On first attach, applies
    /// `initialFrame` to the window (if visible on any screen). After attach,
    /// reports frame changes via `onChange`, debounced.
    func trackWindowFrame(
        initialFrame: CGRect?,
        debounceInterval: TimeInterval = 0.25,
        onChange: @escaping (CGRect) -> Void
    ) -> some View {
        background(
            WindowFrameTracker(
                initialFrame: initialFrame,
                debounceInterval: debounceInterval,
                onFrameChange: onChange
            )
        )
    }
}
