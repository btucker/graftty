import Foundation
import GhosttyKit
import GrafttyKit

/// Owns the consumed action payloads before returning to libghostty. In the
/// pinned renderer, Action.cval borrows its strings and Surface's PWD handler
/// frees its temporary buffer as soon as performAction returns.
/// Unhandled tags never cross the queue, including their borrowed pointers.
enum GhosttyOwnedAction {
    case scrollbar(ghostty_action_scrollbar_s)
    case setTitle(String)
    case pwd(String)
    case ringBell
    case openURL(String)
    case mouseShape(ghostty_action_mouse_shape_e)
    case mouseHidden(Bool)
    case desktopNotification(title: String, body: String)
    case commandFinished(ghostty_action_command_finished_s)
    case paneCommand(HostManagedPaneCommand)
    case reloadConfig
    case openConfig

    init?(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SCROLLBAR:
            self = .scrollbar(action.action.scrollbar)
        case GHOSTTY_ACTION_SET_TITLE:
            self = .setTitle(String(cString: action.action.set_title.title))
        case GHOSTTY_ACTION_PWD:
            self = .pwd(String(cString: action.action.pwd.pwd))
        case GHOSTTY_ACTION_RING_BELL:
            self = .ringBell
        case GHOSTTY_ACTION_OPEN_URL:
            let url = action.action.open_url
            guard let count = Int(exactly: url.len),
                  let value = String(bytes: UnsafeRawBufferPointer(start: url.url, count: count), encoding: .utf8)
            else { return nil }
            self = .openURL(value)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            self = .mouseShape(action.action.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            self = .mouseHidden(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = action.action.desktop_notification
            // ghostty.h declares both strings non-null; an absent title is empty.
            let title = String(cString: note.title)
            self = .desktopNotification(title: title.isEmpty ? "Terminal" : title,
                                        body: String(cString: note.body))
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            self = .commandFinished(action.action.command_finished)
        case GHOSTTY_ACTION_NEW_SPLIT:
            let split: PaneSplit
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_RIGHT: split = .right
            case GHOSTTY_SPLIT_DIRECTION_LEFT: split = .left
            case GHOSTTY_SPLIT_DIRECTION_UP: split = .up
            case GHOSTTY_SPLIT_DIRECTION_DOWN: split = .down
            default: return nil
            }
            self = .paneCommand(.split(split))
        case GHOSTTY_ACTION_CLOSE_TAB:
            self = .paneCommand(.close)
        case GHOSTTY_ACTION_GOTO_SPLIT:
            let command: HostManagedPaneCommand
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_LEFT: command = .focus(.left)
            case GHOSTTY_GOTO_SPLIT_RIGHT: command = .focus(.right)
            case GHOSTTY_GOTO_SPLIT_UP: command = .focus(.up)
            case GHOSTTY_GOTO_SPLIT_DOWN: command = .focus(.down)
            case GHOSTTY_GOTO_SPLIT_NEXT: command = .focusOrder(forward: true)
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: command = .focusOrder(forward: false)
            default: return nil
            }
            self = .paneCommand(command)
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            self = .paneCommand(.toggleZoom)
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = action.action.resize_split
            let direction: ResizeDirection
            switch resize.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: direction = .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: direction = .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: direction = .left
            case GHOSTTY_RESIZE_SPLIT_RIGHT: direction = .right
            default: return nil
            }
            self = .paneCommand(.resize(direction: direction, amount: resize.amount))
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            self = .paneCommand(.equalize)
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            self = .reloadConfig
        case GHOSTTY_ACTION_OPEN_CONFIG:
            self = .openConfig
        default:
            return nil
        }
    }
}

/// Thread-safe callback ingress. The registry lock protects only Swift values;
/// it is never held across C calls, main-queue dispatch, or action delivery.
/// The surface address is an opaque key, never a source of C userdata.
final class GhosttyActionBridge: @unchecked Sendable {
    struct SurfaceIdentity: Equatable, Sendable {
        let terminalID: PaneSlotID
        let generation = UUID()
    }

    enum Target {
        case app
        case surface(SurfaceIdentity)
    }

    private let lock = NSLock()
    private var surfaces: [UInt: SurfaceIdentity] = [:]
    private var creatingSurface: SurfaceIdentity?

    /// Surface.init emits synchronous actions before ghostty_surface_new
    /// returns its address. It runs on main, and embedded.Surface.init sets
    /// userdata before those callbacks. Use the known construction identity
    /// instead of querying C state, and restore it for nested construction.
    func withSurfaceCreation(_ identity: SurfaceIdentity,
                             create: () -> ghostty_surface_t?) -> ghostty_surface_t? {
        precondition(Thread.isMainThread)
        let previous = lock.withLock {
            let previous = creatingSurface
            creatingSurface = identity
            return previous
        }
        defer { lock.withLock { creatingSurface = previous } }
        let surface = create()
        if let surface {
            lock.withLock { surfaces[UInt(bitPattern: surface)] = identity }
        }
        return surface
    }

    func isCreating(_ identity: SurfaceIdentity) -> Bool {
        lock.withLock { creatingSurface == identity }
    }

    /// Called before ghostty_surface_free. A late destructor must not erase a
    /// newer generation if an address was reused.
    func unregister(_ surface: ghostty_surface_t, identity: SurfaceIdentity) {
        lock.withLock {
            let address = UInt(bitPattern: surface)
            if surfaces[address] == identity { surfaces.removeValue(forKey: address) }
        }
    }

    func receive(target: ghostty_target_s, action: ghostty_action_s,
                 deliver: @escaping @MainActor (Target, GhosttyOwnedAction) -> Void) {
        let capturedTarget: Target
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            capturedTarget = .app
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            let identity = lock.withLock {
                surfaces[UInt(bitPattern: surface)] ?? (Thread.isMainThread ? creatingSurface : nil)
            }
            guard let identity else { return }
            capturedTarget = .surface(identity)
        default:
            return
        }
        guard let ownedAction = GhosttyOwnedAction(action) else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliver(capturedTarget, ownedAction) }
        } else {
            DispatchQueue.main.async { deliver(capturedTarget, ownedAction) }
        }
    }
}
