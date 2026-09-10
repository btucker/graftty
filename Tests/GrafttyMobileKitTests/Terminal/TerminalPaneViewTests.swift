#if canImport(UIKit)
import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit
import UIKit

private final class NilInputKeyCommand: UIKeyCommand {
    override var input: String? { nil }
}

private final class TerminalResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ data: Data) {
        lock.withLock { self.data.append(data) }
    }

    func contains(_ response: String) -> Bool {
        lock.withLock { data.range(of: Data(response.utf8)) != nil }
    }
}

@MainActor
private final class DeferredEditMenuAnimator: NSObject, UIEditMenuInteractionAnimating {
    private var completions: [() -> Void] = []

    func addAnimations(_ animations: @escaping () -> Void) {
        animations()
    }

    func addCompletion(_ completion: @escaping () -> Void) {
        completions.append(completion)
    }

    func finish() {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0() }
    }
}

@Suite
@MainActor
struct TerminalPaneViewTests {

    @Test("@spec IOS-11.13: When the user presses and holds a displayed HTTP or HTTPS URL whose terminal cells map unambiguously to the viewport text, the application shall offer Open Link alongside its text-selection actions and open the complete URL in the system browser when chosen. Pressing ordinary text shall not offer Open Link.")
    func longPressOpensTheCompleteURLUnderThePressedWord() throws {
        let container = TerminalInputContainerView(frame: .zero)
        let text = "See https://example.com/first and https://example.org/path?q=hello#part."
        container.terminalView.contentScaleFactor = 1
        container.terminalDidResize(TerminalGridMetrics(
            columns: 100, rows: 1, widthPixels: 1000, heightPixels: 20,
            cellWidthPixels: 10, cellHeightPixels: 20
        ))
        var opened: [URL] = []
        container.openURL = { opened.append($0) }
        container.prepareLongPressMenu(
            at: CGPoint(x: CGFloat((text as NSString).range(of: "hello").location) * 10 + 5, y: 10),
            text: text
        )
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: false) == [
            "Open Link", "Select", "Select All",
        ])
        let action = try #require(container.longPressMenuForTesting(hasPasteContent: false)
            .children.compactMap { $0 as? UIAction }.first { $0.title == "Open Link" })
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(opened.map(\.absoluteString) == ["https://example.org/path?q=hello#part"])
        #expect(!container.selectionController.isActive)

        container.prepareLongPressMenu(
            at: CGPoint(x: 5, y: 10), text: text
        )
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: false) == [
            "Select", "Select All",
        ])
        button.sendActions(for: .touchUpInside)
        #expect(opened.count == 1, "A dismissed menu must not open a stale URL")
    }

    @Test
    func terminalLinksRejectMissingGeometryAndUnsupportedSchemes() {
        let container = TerminalInputContainerView(frame: .zero)
        container.prepareLongPressMenu(at: .zero, text: "https://example.com/path")
        #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
        #expect(TerminalLinkResolver.webURL("file:///tmp/file") == nil)
        #expect(TerminalLinkResolver.webURL("javascript:alert(1)") == nil)
    }

    @Test
    func terminalLinksUsePhysicalRowsAfterASCIIWrapping() {
        let grid = TerminalGridMetrics(
            columns: 40, rows: 12, widthPixels: 400, heightPixels: 240,
            cellWidthPixels: 10, cellHeightPixels: 20
        )
        let text = String(repeating: "a", count: 50)
            + "\n\nhttps://one.example/same\nhttps://two.example/same"
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 215, y: 90), grid: grid, displayScale: 1
        )?.absoluteString == "https://two.example/same")
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 215, y: 50), grid: grid, displayScale: 1
        ) == nil)

        let wrappedURL = "https://example.com/" + String(repeating: "path", count: 15)
        #expect(TerminalLinkResolver.url(
            in: wrappedURL, at: CGPoint(x: 45, y: 30), grid: grid, displayScale: 1
        )?.absoluteString == wrappedURL)
        #expect(TerminalLinkResolver.url(
            in: "界\n" + wrappedURL, at: CGPoint(x: 45, y: 30), grid: grid, displayScale: 1
        ) == nil)
    }

    @Test
    func terminalLinksRequireEveryPossiblePaddedCellToMatch() {
        let grid = TerminalGridMetrics(
            columns: 40, rows: 10, widthPixels: 420, heightPixels: 200,
            cellWidthPixels: 10, cellHeightPixels: 20
        )
        let text = "https://example.com/path ordinary"
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 50, y: 5), grid: grid, displayScale: 2
        )?.absoluteString == "https://example.com/path")
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 120, y: 5), grid: grid, displayScale: 2
        ) == nil)
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 2.5, y: 5), grid: grid, displayScale: 2
        ) == nil, "A possible left margin must not count as the URL's first cell")
        var paddedVertically = grid
        paddedVertically.heightPixels = 220
        #expect(TerminalLinkResolver.url(
            in: text, at: CGPoint(x: 50, y: 2.5), grid: paddedVertically, displayScale: 2
        ) == nil, "A possible top margin must not count as the URL's first row")
    }

    @Test
    func realSurfaceLinksResolveAfterWrappedOutput() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let container = TerminalInputContainerView(frame: window.bounds)
        container.layoutIfNeeded()
        let responses = TerminalResponseRecorder()
        let session = InMemoryTerminalSession(write: { responses.append($0) }, resize: { _ in })
        let renderer = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        container.terminalView.configuration = .init(backend: .inMemory(session))
        container.terminalView.controller = renderer
        host.view.addSubview(container)
        container.layoutIfNeeded()
        defer {
            container.removeFromSuperview()
            window.isHidden = true
        }
        let grid = try #require(container.terminalGridMetrics)
        try #require(grid.rows >= 8)
        // Public UI metrics arrive before the parser resizes. A cursor
        // clamped to the bottom-right proves the parser reached this grid
        // before the fixture can wrap and scroll at its startup dimensions.
        let bottomRight = "\u{1b}[\(grid.rows);\(grid.columns)R"
        for _ in 0..<100 where !responses.contains(bottomRight) {
            session.receive("\u{1b}[999;999H\u{1b}[6n")
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(responses.contains(bottomRight))
        let prefix = String(repeating: "a", count: Int(grid.columns) + 5)
        session.receive("\u{1b}[H\u{1b}[2J" + prefix + "\r\n\r\nhttps://one.example/same\r\nhttps://two.example/same")
        for _ in 0..<100 where session.readViewportText()?.contains("https://two.example/same") != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = try #require(session.readViewportText())
        #expect(container.terminalGridMetrics == grid)
        #expect(text.hasPrefix(prefix + "\n\n"), "Soft wraps join, while hard blank rows remain. Grid: \(grid)")
        let cellHeight = CGFloat(grid.cellHeightPixels)
        let unusedHeight = CGFloat(grid.heightPixels) - CGFloat(grid.rows) * cellHeight
        try #require(unusedHeight < cellHeight)
        let scale = container.terminalView.contentScaleFactor
        let point = CGPoint(
            x: CGFloat(grid.cellWidthPixels) * 15.5 / scale,
            y: (cellHeight * 4 + (cellHeight + unusedHeight) / 2) / scale
        )
        var opened: URL?
        container.openURL = { opened = $0 }
        container.prepareLongPressMenu(at: point, text: text)
        let action = try #require(container.longPressMenuForTesting(hasPasteContent: false)
            .children.compactMap { $0 as? UIAction }.first { $0.title == "Open Link" })
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(opened?.absoluteString == "https://two.example/same")
    }

    @Test("When the terminal surface is replaced, selection and cached link targets are discarded")
    func detachedSurfaceClearsSelectionAndLinks() {
        let container = TerminalInputContainerView(frame: .zero)
        container.terminalView.contentScaleFactor = 1
        container.terminalDidResize(TerminalGridMetrics(
            columns: 100, rows: 1, widthPixels: 1000, heightPixels: 20,
            cellWidthPixels: 10, cellHeightPixels: 20
        ))
        container.selectionController.beginSelection(at: .zero)
        container.enterSelectionModeForTesting()
        container.prepareLongPressMenu(at: CGPoint(x: 100, y: 10), text: "https://example.com/old-surface")
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
        container.terminalDidDetachSurface()
        #expect(!container.selectionController.isActive)
        #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
        container.prepareLongPressMenu(at: .zero, text: "New text")
        #expect(!container.longPressMenuActionTitlesForTesting(hasPasteContent: false).contains("Open Link"))
        #expect(container.terminalPanRecognizersAllowIndirectScrollingForTesting)
    }

    @Test
    func terminalDoesNotExposeGhosttyAccessoryView() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(!container.terminalView.showsInputAccessory)
        #expect(container.terminalView.inputAccessoryView == nil)
    }

    @Test("""
@spec IOS-6.7: While a terminal pane is rendered in the iOS app, `UITerminalView` shall remain the sole terminal keyboard responder and its supported `showsInputAccessory` property shall be false, so the GhosttyKit accessory is absent without Objective-C runtime swizzling. The only visible software-keyboard accessory row shall be GrafttyMobile's terminal control bar (`IOS-6.1`).
""")
    func terminalPaneShowsOnlyGrafttyKeyboardAccessory() {
        let container = TerminalInputContainerView(frame: .zero)

        #expect(!container.terminalView.showsInputAccessory)
        #expect(container.terminalView.inputAccessoryView == nil)
    }

    @Test("""
@spec IOS-6.8: While no authoritative checkpoint grid is set, the terminal shall fill its container, remain its rendering touch target, and retain libghostty-spm's built-in pan-to-scroll and pinch-to-zoom gestures.
""")
    func terminalViewIsSoleFullSizeSubviewAndTouchTarget() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.layoutIfNeeded()

        let hitView = container.hitTest(CGPoint(x: 160, y: 120), with: nil)

        #expect(container.terminalView.superview === container.snapshotScrollView)
        #expect(!container.snapshotScrollView.isScrollEnabled)
        #expect(container.terminalView.frame == container.bounds)
        #expect(hitView === container.terminalView)
        #expect(!container.terminalView.canBecomeFirstResponder)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        #expect(container.terminalView.canBecomeFirstResponder)
    }

    @Test("""
@spec IOS-6.17: While a terminal pane is rendered on iPad with a trackpad, indirect pointer scroll gestures shall reach libghostty's terminal scroll/input recognizers on the sole `UITerminalView` touch surface, with no GrafttyMobile keyboard or selection overlay blocking them.
""")
    func terminalPanRecognizersAllowIndirectScrolling() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.terminalPanRecognizersAllowIndirectScrollingForTesting)
    }

    @Test("""
@spec IOS-11.1: While a focused terminal pane is interactive, the application shall handle libghostty's built-in long-press selection request through `TerminalInputContainerView` and present a menu at the touch point containing **Select**, **Select All**, and (when the clipboard contains text or an image at menu-build time) **Paste**, without installing a competing long-press recognizer on the container.
""")
    func terminalLongPressUsesGhosttySelectionRequestDelegate() throws {
        let container = TerminalInputContainerView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
        let terminalLongPress = try #require(
            container.terminalView.gestureRecognizers?
                .compactMap { $0 as? UILongPressGestureRecognizer }
                .first
        )

        #expect(container.terminalView.delegate === container)
        #expect(container.terminalView.gestureRecognizerShouldBegin(terminalLongPress))
        #expect(container.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer } == false)
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: false) == [
            "Select", "Select All",
        ])
        #expect(container.longPressMenuActionTitlesForTesting(hasPasteContent: true) == [
            "Select", "Select All", "Paste",
        ])
    }

    @Test("""
@spec IPAD-9.9: The `TerminalInputContainerView` in the active iPad terminal responder chain shall publish app-level Ghostty shortcuts as priority `UIKeyCommand`s for system arbitration and discoverability, and shall install itself as `UITerminalView`'s hardware-input delegate so the actual first responder dispatches the same enabled command candidates before Ghostty consumes raw presses. It shall publish priority correction commands only for Return, quote, Escape, and Tab, handle Ctrl-letter corrections through the delegate without adding 26 discoverability commands, synchronously request a UIKit menu-system rebuild whenever effective command metadata changes, and prefer an app-level shortcut on an exact chord collision. Every other unmatched terminal hardware key shall remain owned by `UITerminalView`.
""")
    func activeTerminalInputResponderRefreshesPublishedHardwareKeyboardCommands() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.keyCommands == nil)
        #expect(container.keyCommandUpdateRequestCountForTesting == 0)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
            .init(
                id: "next-worktree",
                title: "Next Worktree",
                input: "\t",
                modifierFlags: [.control],
                perform: {}
            ),
        ]

        #expect(container.keyCommandUpdateRequestCountForTesting == 1)
        let publishedCommands = try! #require(container.keyCommands)
        #expect(publishedCommands.count == 2)
        #expect(publishedCommands[0].input == "d")
        #expect(publishedCommands[0].modifierFlags == [.command])
        #expect(publishedCommands[1].input == "\t")
        #expect(publishedCommands[1].modifierFlags == [.control])
        for command in publishedCommands {
            #expect(command.wantsPriorityOverSystemBehavior)
        }
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 2)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 3)
        #expect(container.keyCommands?.first?.input == "j")

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command, .shift],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 4)
        #expect(container.keyCommands?.first?.modifierFlags == [.command, .shift])

        container.hardwareKeyboardCommands = []
        #expect(container.keyCommandUpdateRequestCountForTesting == 5)
        #expect(container.keyCommands == nil)
    }

    @Test("""
@spec IOS-6.19: While an owner terminal pane is the eligible iPad hardware-keyboard target, `UITerminalView` shall offer each physical press to Graftty's hardware-input delegate before Ghostty translation. The delegate shall intercept enabled app commands plus unmodified Return, unmodified apostrophe, Shift-apostrophe, unmodified Escape, unmodified Tab, and Ctrl+A through Ctrl+Z, using logical UIKit characters ahead of suspect HID usage. It shall forward the exact terminal text or ASCII control byte for each correction. An app-level shortcut shall win an exact chord collision. Shift-Return and every other unmatched hardware key shall return to `UITerminalView`, and an ineligible pane shall expose no transport corrections.
""")
    func terminalHardwareCorrectionsForwardExactTextOnlyWhileEligible() {
        let container = TerminalInputContainerView(frame: .zero)
        var texts: [String] = []
        var controlBytes: [UInt8] = []

        #expect(container.keyCommands == nil)
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) },
            insertControlByte: { controlBytes.append($0) },
            deleteBackward: {}
        )

        let correctionCommands = try! #require(container.keyCommands)
        #expect(correctionCommands.count == 5)
        #expect(correctionCommands.map(\.input) == [
            "\r", "'", "'", UIKeyCommand.inputEscape, "\t",
        ])
        #expect(correctionCommands.map(\.modifierFlags) == [[], [], [.shift], [], []])
        #expect(correctionCommands.allSatisfy { $0.wantsPriorityOverSystemBehavior })

        // Model the crossed HID values seen on the physical iPad: logical
        // characters must win or apostrophe would still dispatch Return.
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: 0x34,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                modifierFlags: []
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: 0x28,
                characters: "'",
                charactersIgnoringModifiers: "'",
                modifierFlags: []
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: 0x28,
                characters: "\"",
                charactersIgnoringModifiers: "'",
                modifierFlags: [.shift]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardEscape.rawValue),
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: []
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardTab.rawValue),
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                modifierFlags: []
            )
        ))
        // Shift-Return is intentionally not reserved: it must keep flowing to
        // Ghostty so bindings such as `shift+enter=text:\\n` remain effective.
        #expect(!container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardReturnOrEnter.rawValue),
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                modifierFlags: [.shift]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardA.rawValue),
                characters: "\u{1}",
                charactersIgnoringModifiers: "a",
                modifierFlags: [.control]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardJ.rawValue),
                characters: "\n",
                charactersIgnoringModifiers: "j",
                modifierFlags: [.control]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardZ.rawValue),
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: [.control]
            )
        ))
        #expect(!container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardA.rawValue),
                characters: ";",
                charactersIgnoringModifiers: ";",
                modifierFlags: [.control]
            )
        ))
        #expect(texts == ["\r", "'", "\"", "\u{1B}", "\t"])
        #expect(controlBytes == [0x01, 0x0A, 0x1A])

        var appEscapeCount = 0
        var appControlXCount = 0
        container.hardwareKeyboardCommands = [
            .init(
                id: "app-escape",
                title: "App Escape",
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                perform: { appEscapeCount += 1 }
            ),
            .init(
                id: "app-control-x",
                title: "App Control X",
                input: "x",
                modifierFlags: [.control],
                perform: { appControlXCount += 1 }
            ),
        ]
        #expect(container.keyCommands?.count == 6)
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardEscape.rawValue),
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: []
            )
        ))
        #expect(appEscapeCount == 1)
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardX.rawValue),
                characters: "\u{18}",
                charactersIgnoringModifiers: "",
                modifierFlags: [.control]
            )
        ))
        #expect(appControlXCount == 1)
        #expect(texts == ["\r", "'", "\"", "\u{1B}", "\t"])
        #expect(controlBytes == [0x01, 0x0A, 0x1A])

        container.hardwareKeyboardCommands = []
        container.committedSoftwareInput = nil
        #expect(container.keyCommands == nil)
        #expect(!container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: 0x34,
                characters: "'",
                charactersIgnoringModifiers: "'",
                modifierFlags: []
            )
        ))
        #expect(texts == ["\r", "'", "\"", "\u{1B}", "\t"])
        #expect(controlBytes == [0x01, 0x0A, 0x1A])
    }

    @Test("the terminal first responder delegates application hardware chords before Ghostty")
    func terminalHardwareInputDelegateDispatchesApplicationChords() {
        let container = TerminalInputContainerView(frame: .zero)
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("split") }
            ),
            .init(
                id: "next-pane",
                title: "Next Pane",
                input: "\t",
                modifierFlags: [.control],
                perform: { performed.append("pane") }
            ),
        ]

        #expect((container.terminalView.hardwareInputDelegate as AnyObject?) === container)
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardD.rawValue),
                characters: "D",
                charactersIgnoringModifiers: "D",
                modifierFlags: [.command, .numericPad]
            )
        ))
        #expect(container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardTab.rawValue),
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                modifierFlags: [.control]
            )
        ))
        #expect(!container.terminalView(
            container.terminalView,
            handleHardwareKey: .init(
                usage: UInt16(UIKeyboardHIDUsage.keyboardD.rawValue),
                characters: "D",
                charactersIgnoringModifiers: "D",
                modifierFlags: [.command, .shift]
            )
        ))
        #expect(performed == ["split", "pane"])
    }

    @Test("equivalent hardware command signatures retain UIKit's table and replace dispatch closures")
    func equivalentHardwareCommandSignatureUsesReplacementClosureWithoutInvalidation() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("old") }
            ),
        ]

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command, .numericPad],
                perform: { performed.append("new") }
            ),
        ]

        #expect(container.keyCommandUpdateRequestCountForTesting == 1)
        #expect(container.keyCommands?.first?.modifierFlags == [.command])
        container.performHardwareKeyboardCommandForTesting(
            input: "d",
            modifierFlags: [.command, .numericPad]
        )
        #expect(performed == ["new"])
    }

    @Test("changed hardware command titles request a menu rebuild")
    func changedHardwareCommandTitleRequestsMenuRebuild() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        #expect(container.keyCommandUpdateRequestCountForTesting == 2)
        #expect(container.keyCommands?.first?.title == "Split Pane Right")
        #expect(container.keyCommands?.first?.discoverabilityTitle == "Split Pane Right")
    }

    @Test("hardware command dispatch requires an exact normalized input and modifier match")
    func hardwareCommandDispatchUsesExactNormalizedMatch() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var performed = 0
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed += 1 }
            ),
        ]

        container.performHardwareKeyboardCommandForTesting(input: "D", modifierFlags: [.command])
        container.performHardwareKeyboardCommandForTesting(input: "d", modifierFlags: [.command, .shift])
        #expect(performed == 0)

        container.performHardwareKeyboardCommandForTesting(
            input: "d",
            modifierFlags: [.command, .numericPad]
        )
        #expect(performed == 1)
    }

    @Test("stale cached hardware commands are rejected while current commands remain dispatchable")
    func staleCachedHardwareCommandIsRejected() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("old") }
            ),
        ]
        let staleCommand = try! #require(container.keyCommands?.first)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: { performed.append("current") }
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
        let commandAction = try! #require(currentCommand.action)

        #expect(!container.canPerformAction(commandAction, withSender: staleCommand))
        #expect(container.canPerformAction(commandAction, withSender: currentCommand))

        container.perform(commandAction, with: currentCommand)
        #expect(performed == ["current"])
    }

    @Test("stale cached command identity is rejected when its chord is reused")
    func staleCachedHardwareCommandWithReusedChordIsRejected() {
        let container = TerminalInputContainerView(frame: .zero)
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("old") }
            ),
        ]
        let staleCommand = try! #require(container.keyCommands?.first)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("retitled") }
            ),
        ]
        let retitledCommand = try! #require(container.keyCommands?.first)
        let commandAction = try! #require(retitledCommand.action)

        #expect(!container.canPerformAction(commandAction, withSender: staleCommand))
        container.perform(commandAction, with: staleCommand)
        #expect(performed.isEmpty)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("new") }
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
        #expect(!container.canPerformAction(commandAction, withSender: retitledCommand))
        container.perform(commandAction, with: retitledCommand)
        #expect(performed.isEmpty)

        #expect(container.canPerformAction(commandAction, withSender: currentCommand))
        container.perform(commandAction, with: currentCommand)
        #expect(performed == ["new"])
    }

    @Test("hardware command validation rejects nil input and mismatched modifiers")
    func hardwareCommandValidationRequiresExactNormalizedMatch() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
        let commandAction = try! #require(currentCommand.action)
        let nilInputCommand = NilInputKeyCommand(
            title: "Missing Input",
            action: commandAction,
            input: "j",
            modifierFlags: [.command]
        )
        let mismatchedModifierCommand = UIKeyCommand(
            title: "Wrong Modifiers",
            action: commandAction,
            input: "j",
            modifierFlags: [.command, .shift]
        )

        #expect(!container.canPerformAction(commandAction, withSender: nilInputCommand))
        #expect(!container.canPerformAction(commandAction, withSender: mismatchedModifierCommand))
    }

    @Test("ordinary reconstructed key commands validate stable identity and title")
    func reconstructedHardwareCommandValidatesStableIdentityAndTitle() {
        let container = TerminalInputContainerView(frame: .zero)
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        let action = try! #require(container.keyCommands?.first?.action)

        let matching = UIKeyCommand(
            title: "Split Down",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-down",
            alternates: [],
            discoverabilityTitle: "Split Down",
            attributes: [],
            state: .off
        )
        let staleID = UIKeyCommand(
            title: "Split Down",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-right",
            alternates: [],
            discoverabilityTitle: "Split Down",
            attributes: [],
            state: .off
        )
        let staleTitle = UIKeyCommand(
            title: "Split Right",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-down",
            alternates: [],
            discoverabilityTitle: "Split Right",
            attributes: [],
            state: .off
        )

        #expect(container.canPerformAction(action, withSender: matching))
        #expect(!container.canPerformAction(action, withSender: staleID))
        #expect(!container.canPerformAction(action, withSender: staleTitle))
    }

    @Test("hardware command changes do not alter unrelated action validation")
    func unrelatedActionValidationIsUnchanged() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let action = #selector(UIResponderStandardEditActions.copy(_:))
        let resultBeforeCommand = container.canPerformAction(action, withSender: nil)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        #expect(container.canPerformAction(action, withSender: nil) == resultBeforeCommand)
    }

    @Test("keyCommands are cached between queries and invalidated on signature change")
    func keyCommandsAreCachedUntilSignatureChanges() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.hardwareKeyboardCommands = [
            .init(id: "split-right", title: "Split Right", input: "d", modifierFlags: [.command], perform: {}),
        ]

        // UIKit queries keyCommands on every hardware key-down; repeated
        // queries must return the cached objects, not fresh allocations.
        let first = container.keyCommands?.first
        let second = container.keyCommands?.first
        #expect(first != nil)
        #expect(first === second)

        // A signature-equal update (fresh closures, same chords) keeps the cache.
        container.hardwareKeyboardCommands = [
            .init(id: "split-right", title: "Split Right", input: "d", modifierFlags: [.command], perform: {}),
        ]
        #expect(container.keyCommands?.first === first)

        // A real signature change rebuilds.
        container.hardwareKeyboardCommands = [
            .init(id: "split-down", title: "Split Down", input: "j", modifierFlags: [.command], perform: {}),
        ]
        let rebuilt = container.keyCommands?.first
        #expect(rebuilt !== first)
        #expect(rebuilt?.input == "j")
    }

    @Test("selection mode keeps indirect terminal pan recognizers enabled")
    func selectionModeKeepsIndirectScrollingEnabled() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        container.enterSelectionModeForTesting()

        let pans = container.terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        #expect(!pans.isEmpty)
        #expect(pans.allSatisfy { $0.isEnabled })
    }

    @Test("""
@spec IOS-11.4: While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and the active terminal or checkpoint-canvas scroll recognizers shall stop receiving direct touches (indirect trackpad/mouse scrolling stays enabled) until selection mode exits.
""")
    func selectionModeStripsDirectTouchesFromScrollPans() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let maskedPans = {
            (container.terminalView.gestureRecognizers ?? [])
                .compactMap { $0 as? UIPanGestureRecognizer }
                .filter { !$0.allowedScrollTypesMask.isEmpty }
        }
        let savedTouchTypes = maskedPans().map(\.allowedTouchTypes)
        #expect(!maskedPans().isEmpty)

        container.enterSelectionModeForTesting()
        // allowedScrollTypesMask only adds indirect scroll recognition; the
        // direct-touch block must come from narrowing allowedTouchTypes.
        #expect(maskedPans().allSatisfy {
            $0.allowedTouchTypes == TerminalInputContainerView.indirectPointerOnlyTouchTypes
        })

        container.exitSelectionModeForTesting()
        #expect(maskedPans().map(\.allowedTouchTypes) == savedTouchTypes)
    }

    @Test("focus requests remain pending until the terminal can become first responder")
    func focusRequestNotConsumedUntilTerminalCanFocus() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let coordinator = TerminalPaneView.Coordinator()
        var consumedCount = 0
        coordinator.onFocusRequestsConsumed = { consumedCount += 1 }
        container.committedSoftwareInput = nil

        coordinator.applyFocusRequest(1, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(consumedCount == 0)

        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        coordinator.applyFocusRequest(1, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(consumedCount == 1)
        #expect(container.terminalView.isFirstResponder)
    }

    @Test("""
@spec IPAD-8.9: When a terminal pane remounts with zero pending focus requests (all prior requests already honored and consumed), the application shall not call becomeFirstResponder, so a keyboard the user dismissed is not re-summoned by idle-snapshot swaps or other view recreations.
""")
    func remountWithNoPendingFocusRequestsDoesNotSummonKeyboard() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // Keyboard-eligible: a stale-total replay would succeed if attempted.
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        // A remount creates a fresh Coordinator with no memory; the counter
        // owners survive the remount and report zero pending requests.
        let freshCoordinator = TerminalPaneView.Coordinator()
        var consumedCount = 0
        freshCoordinator.onFocusRequestsConsumed = { consumedCount += 1 }
        freshCoordinator.applyFocusRequest(0, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(consumedCount == 0)
        #expect(!container.terminalView.isFirstResponder)
    }

    @Test("""
@spec IOS-11.12: When the user taps Paste from the terminal long-press edit menu, the application shall forward the clipboard paste request and re-focus the eligible `UITerminalView` after UIKit's edit-menu dismissal completes, so the dismissal cannot subsequently resign the terminal and leave the user without keyboard control.
""")
    func pasteMenuRefocusesEligibleTerminalAfterDismissalCompletes() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        var didRequestPaste = false
        container.onPasteRequested = { didRequestPaste = true }

        let animator = DeferredEditMenuAnimator()
        container.dismissLongPressMenuForTesting(animator: animator)
        // UIKit is allowed to begin dismissal before invoking the selected
        // action. Register the completion first to cover that ordering.
        container.performPasteForTesting()

        #expect(didRequestPaste)
        #expect(!container.terminalView.isFirstResponder)

        animator.finish()

        // The refocus deliberately leaves UIKit's dismissal-completion turn.
        #expect(!container.terminalView.isFirstResponder)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(container.terminalView.isFirstResponder)
        _ = window
    }

    @Test("Paste refocuses when edit-menu dismissal completes before the action callback")
    func pasteMenuRefocusesWhenDismissalCompletesBeforeAction() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        var didRequestPaste = false
        container.onPasteRequested = { didRequestPaste = true }

        let animator = DeferredEditMenuAnimator()
        container.dismissLongPressMenuForTesting(animator: animator)
        animator.finish()
        container.performPasteForTesting()

        #expect(didRequestPaste)
        #expect(!container.terminalView.isFirstResponder)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(container.terminalView.isFirstResponder)
        _ = window
    }

    @Test("selection-menu dismissal cannot consume a pending Paste refocus")
    func selectionMenuDismissalDoesNotConsumePendingPasteRefocus() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        container.performPasteForTesting()
        let selectionAnimator = DeferredEditMenuAnimator()
        container.dismissSelectionMenuForTesting(animator: selectionAnimator)
        selectionAnimator.finish()

        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(!container.terminalView.isFirstResponder)

        let longPressAnimator = DeferredEditMenuAnimator()
        container.dismissLongPressMenuForTesting(animator: longPressAnimator)
        longPressAnimator.finish()

        #expect(!container.terminalView.isFirstResponder)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(container.terminalView.isFirstResponder)
        _ = window
    }

    @Test("any touch on the terminal container fires onUserInteraction")
    func touchBeganFiresUserInteraction() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var fired = 0
        container.onUserInteraction = { fired += 1 }

        container.simulateAnyTouchBeganForTesting()

        #expect(fired == 1)
    }

    @Test("""
@spec IOS-6.6: While an owner terminal pane is focused on iOS, committed software-keyboard text and delete shall flow through `UITerminalView`'s supported `TerminalSoftwareInputDelegate` and be forwarded exactly once to `SessionClient.sendSoftwareKeyboardText(_:)` and `deleteBackward()`. A single software-keyboard newline shall be translated to CR (`0x0D`) per `IOS-6.3`, and delete shall send DEL (`0x7F`), without using Ghostty's paste-text path.
""")
    func committedSoftwareInputDelegateForwardsExactlyOnce() {
        let container = TerminalInputContainerView(frame: .zero)
        var texts: [String] = []
        var deletes = 0
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) },
            deleteBackward: { deletes += 1 }
        )

        #expect(container.terminalView.softwareInputDelegate === container)
        container.terminalView.insertText("hello")
        container.terminalView.deleteBackward()
        #expect(texts == ["hello"])
        #expect(deletes == 1)
    }

    @Test("ineligible terminal consumes pending committed input after owner loss")
    func ownerLossConsumesPendingCommittedInputWithoutForwarding() {
        let container = TerminalInputContainerView(frame: .zero)
        let delegate: any TerminalSoftwareInputDelegate = container
        var texts: [String] = []
        var deletes = 0
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) },
            deleteBackward: { deletes += 1 }
        )

        container.committedSoftwareInput = nil

        #expect(delegate.terminalView(container.terminalView, insertText: "pending"))
        #expect(delegate.terminalViewDeleteBackward(container.terminalView))
        #expect(texts.isEmpty)
        #expect(deletes == 0)
        #expect(!container.terminalView.isKeyboardInputEnabled)
    }

    @Test("""
@spec IOS-6.2: `UITerminalView` shall be the sole terminal keyboard responder and the primary owner of rendering and hardware-key event translation for every iOS pane. Before Ghostty translation it may delegate enabled application commands and the listed transport corrections in `IOS-6.19`; every unmatched key, including arrows, shall flow through libghostty, and GrafttyMobile shall not reimplement general terminal key translation.
""")
    func eligibleTerminalBecomesFirstResponderInWindow() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        #expect(container.terminalView.becomeFirstResponder())
        #expect(container.terminalView.isFirstResponder)
        #expect(container.terminalView.next === container.snapshotScrollView)
        #expect(container.snapshotScrollView.next === container)

        container.committedSoftwareInput = nil
        #expect(!container.terminalView.isFirstResponder)
        #expect(!container.terminalView.canBecomeFirstResponder)
    }

    @Test("""
@spec IOS-6.18: When a hardware press does not match an enabled application command or a Return/quote/Escape/Tab/Ctrl-letter correction in `IOS-6.19`, the sole `UITerminalView` responder shall pass it to libghostty's hardware-key translation. GrafttyMobile shall not install any other per-key handlers; explicit control-bar Escape remains a `SessionClient.sendEscape()` command under `IOS-6.1`.
""")
    func containerPublishesNoGeneralTerminalKeyCommands() {
        let container = TerminalInputContainerView(frame: .zero)

        #expect(container.keyCommands == nil)
    }
}

#endif
