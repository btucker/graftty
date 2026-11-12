#if os(macOS)
import AppKit

/// Visits the accessibility tree under `root` (and its views) until `visit` returns true.
/// SwiftUI's accessibility nodes answer the selectors without formally adopting
/// `NSAccessibilityProtocol`, so they are sent directly.
@MainActor
private func visitAccessibilityElements(in root: NSView, _ visit: (NSObject) -> Bool) {
    let childrenSelector = NSSelectorFromString("accessibilityChildren")
    var pending: [NSObject] = [root]
    var seen: Set<ObjectIdentifier> = []
    while let object = pending.popLast(), seen.count < 8192 {
        guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
        if visit(object) { return }
        if object.responds(to: childrenSelector),
           let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] {
            pending.append(contentsOf: children)
        }
        if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
    }
}

@MainActor
private func hasAccessibilityIdentifier(_ object: NSObject, _ identifier: String) -> Bool {
    let selector = NSSelectorFromString("accessibilityIdentifier")
    return object.responds(to: selector) && object.perform(selector)?.takeUnretainedValue() as? String == identifier
}

@MainActor
private func accessibilityFrame(of object: NSObject) -> NSRect? {
    typealias RectGetter = @convention(c) (AnyObject, Selector) -> NSRect
    let selector = NSSelectorFromString("accessibilityFrame")
    guard object.responds(to: selector) else { return nil }
    return unsafeBitCast(object.method(for: selector), to: RectGetter.self)(object, selector)
}

/// The screen frame of the first hosted accessibility element with `identifier`.
@MainActor
func accessibilityFrame(_ identifier: String, in root: NSView) -> NSRect? {
    var frame: NSRect?
    visitAccessibilityElements(in: root) { object in
        guard hasAccessibilityIdentifier(object, identifier) else { return false }
        frame = accessibilityFrame(of: object)
        return frame != nil
    }
    return frame
}

/// Activates the hosted SwiftUI control with `identifier` without synthesizing
/// input from outside the window: an accessibility press when the element
/// accepts one, else a click at its accessibility frame. False when no element
/// has that identifier.
@MainActor
func accessibilityPress(_ identifier: String, in root: NSView) -> Bool {
    typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    let pressSelector = NSSelectorFromString("accessibilityPerformPress")
    var pressed = false
    visitAccessibilityElements(in: root) { object in
        guard hasAccessibilityIdentifier(object, identifier) else { return false }
        if object.responds(to: pressSelector),
           unsafeBitCast(object.method(for: pressSelector), to: BoolGetter.self)(object, pressSelector) {
            pressed = true
            return true
        }
        guard let frame = accessibilityFrame(of: object), let window = root.window else { return false }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { return true }
            window.sendEvent(event)
        }
        pressed = true
        return true
    }
    return pressed
}
#endif
