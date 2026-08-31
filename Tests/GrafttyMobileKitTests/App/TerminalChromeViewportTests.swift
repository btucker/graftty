import CoreGraphics
import Foundation
import Testing
@testable import GrafttyMobileKit

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import GhosttyTerminal
import UIKit
#endif

@Suite("""
@spec IOS-6.11: While mobile terminal chrome is overlaid at the bottom of a
fullscreen session, the terminal viewport used for rendering and font-fit
decisions shall reserve that measured chrome height. The visual overlay
placement remains bottom-aligned; only the terminal content size is reduced.
""")
struct TerminalChromeViewportTests {

    @Test
    func fullSoftwareKeyboardControlBarReducesTerminalHeight() {
        let container = CGSize(width: 390, height: 502)

        let terminal = TerminalChromeViewport.terminalSize(
            container: container,
            chromeHeight: 58
        )

        #expect(terminal.width == 390)
        #expect(terminal.height == 444)
    }

    @Test
    func compactShowKeyboardAffordanceReducesTerminalHeight() {
        let container = CGSize(width: 390, height: 502)

        let terminal = TerminalChromeViewport.terminalSize(
            container: container,
            chromeHeight: 52
        )

        #expect(terminal.width == 390)
        #expect(terminal.height == 450)
    }

    @Test
    func zeroOrUnknownChromeUsesFullContainerHeight() {
        let container = CGSize(width: 390, height: 502)

        #expect(TerminalChromeViewport.terminalSize(
            container: container,
            chromeHeight: 0
        ) == container)
        #expect(TerminalChromeViewport.terminalSize(
            container: container,
            chromeHeight: nil
        ) == container)
    }

    @Test
    func terminalHeightClampsToAtLeastOnePoint() {
        let terminal = TerminalChromeViewport.terminalSize(
            container: CGSize(width: 390, height: 40),
            chromeHeight: 58
        )

        #expect(terminal.width == 390)
        #expect(terminal.height == 1)
    }

    @Test
    func fontFitTaskKeyIncludesReducedTerminalHeight() {
        let withFullBar = TerminalFontFitTaskKey(
            containerSize: CGSize(width: 390, height: 444),
            authoritativeCols: 120,
            isOwner: false,
            baseConfig: "font-size = 11"
        )
        let withCompactAffordance = TerminalFontFitTaskKey(
            containerSize: CGSize(width: 390, height: 450),
            authoritativeCols: 120,
            isOwner: false,
            baseConfig: "font-size = 11"
        )

        #expect(withFullBar != withCompactAffordance)
    }
}

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
@Suite("""
@spec IOS-6.1: While the software keyboard is visible, the application shall render a compact terminal control bar above the keyboard with Esc, Tab, sticky Ctrl, Ctrl-C, Ctrl-D, arrows, submit Return, literal LF, and Hide Keyboard controls. The non-modifier controls shall send their explicit terminal bytes through `SessionClient`. Tapping sticky Ctrl once shall arm it for the next software-keyboard letter, tapping it twice shall lock it, and libghostty shall translate Ctrl+A through Ctrl+Z to ASCII bytes `0x01` through `0x1A`. When terminal input becomes ineligible, the application shall clear sticky Ctrl state.
""")
@MainActor
struct MobileTerminalControlBarTests {
    @Test("the control bar keeps Tab visible and puts sticky Ctrl beside it")
    func layoutContainsTabAndStickyControl() {
        #expect(SingleSessionView.terminalControlBarItems == [
            .escape,
            .tab,
            .stickyControl,
            .controlC,
            .controlD,
            .navigationDivider,
            .left,
            .down,
            .up,
            .right,
            .returnDivider,
            .submitReturn,
            .literalLineFeed,
            .hideKeyboard,
        ])
    }

    @Test("sticky Ctrl uses libghostty for arbitrary software-keyboard letters")
    func stickyControlLettersSendAsciiControlBytes() {
        let recorder = ThreadSafeDataRecorder()
        let session = InMemoryTerminalSession(
            write: { recorder.append($0) },
            resize: { _ in }
        )
        let container = TerminalInputContainerView(frame: .zero)
        container.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        var activations: [TerminalInputContainerView.StickyControlActivation] = []
        container.setStickyControlActivationChangeHandler { activations.append($0) }

        container.toggleStickyControlModifier()
        #expect(container.stickyControlActivation == .armed)
        container.terminalView.insertText("a")
        #expect(container.stickyControlActivation == .inactive)

        container.toggleStickyControlModifier()
        container.terminalView.insertText("j")

        container.toggleStickyControlModifier()
        container.terminalView.insertText("z")

        #expect(recorder.values == [Data([0x01]), Data([0x0A]), Data([0x1A])])
        #expect(activations == [
            .armed, .inactive,
            .armed, .inactive,
            .armed, .inactive,
        ])
    }

    @Test("normal typing does not disconnect the sticky Ctrl state observer")
    func ordinaryTextKeepsStickyControlObserverAttached() {
        let container = TerminalInputContainerView(frame: .zero)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        var activations: [TerminalInputContainerView.StickyControlActivation] = []
        container.setStickyControlActivationChangeHandler { activations.append($0) }

        container.terminalView.insertText("x")
        container.toggleStickyControlModifier()

        #expect(activations == [.armed])
        #expect(container.stickyControlActivation == .armed)
    }

    @Test("double-tapping sticky Ctrl locks it until reset")
    func stickyControlDoubleTapLocks() {
        let container = TerminalInputContainerView(frame: .zero)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        container.toggleStickyControlModifier()
        container.toggleStickyControlModifier()
        #expect(container.stickyControlActivation == .locked)

        container.committedSoftwareInput = nil
        #expect(container.stickyControlActivation == .inactive)

        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        container.toggleStickyControlModifier()
        container.resetStickyModifiers()
        #expect(container.stickyControlActivation == .inactive)
    }
}

private final class ThreadSafeDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ value: Data) {
        lock.withLock { storage.append(value) }
    }
}
#endif
