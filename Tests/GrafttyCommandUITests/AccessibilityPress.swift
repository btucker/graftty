#if os(macOS)
import AppKit

/// Activates the hosted SwiftUI control with `identifier` without synthesizing
/// input from outside the window: an accessibility press when the element
/// accepts one, else a click at its accessibility frame. False when no element
/// has that identifier. SwiftUI's accessibility nodes answer the selectors
/// without formally adopting `NSAccessibilityProtocol`, so they are sent directly.
@MainActor
func accessibilityPress(_ identifier: String, in root: NSView) -> Bool {
    typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    typealias RectGetter = @convention(c) (AnyObject, Selector) -> NSRect
    let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
    let childrenSelector = NSSelectorFromString("accessibilityChildren")
    let pressSelector = NSSelectorFromString("accessibilityPerformPress")
    let frameSelector = NSSelectorFromString("accessibilityFrame")
    var pending: [NSObject] = [root]
    var seen: Set<ObjectIdentifier> = []
    while let object = pending.popLast(), seen.count < 8192 {
        guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
        if object.responds(to: identifierSelector),
           object.perform(identifierSelector)?.takeUnretainedValue() as? String == identifier {
            if object.responds(to: pressSelector),
               unsafeBitCast(object.method(for: pressSelector), to: BoolGetter.self)(object, pressSelector) {
                return true
            }
            if object.responds(to: frameSelector), let window = root.window {
                let frame = unsafeBitCast(object.method(for: frameSelector), to: RectGetter.self)(object, frameSelector)
                let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                    else { return false }
                    window.sendEvent(event)
                }
                return true
            }
        }
        if object.responds(to: childrenSelector),
           let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] {
            pending.append(contentsOf: children)
        }
        if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
    }
    return false
}
#endif
