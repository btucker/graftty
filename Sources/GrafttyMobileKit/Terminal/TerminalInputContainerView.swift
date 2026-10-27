#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

public final class TerminalInputContainerView: UIView,
    TerminalSoftwareInputDelegate,
    TerminalHardwareInputDelegate
{
    var controlAttachmentID: UUID? {
        didSet { if controlAttachmentID != oldValue { cancelPendingApplicationScroll() } }
    }
    public enum StickyControlActivation: Equatable, Sendable {
        case inactive
        case armed
        case locked
    }

    let terminalView = MobileTerminalInputView(frame: .zero)
    /// The session behind `terminalView`, read for the timeline's jump to terminal.
    weak var scrollbackSession: InMemoryTerminalSession?
    private(set) lazy var snapshotScrollView = TerminalSnapshotScrollView(terminalView: terminalView)
    var onPhysicalViewportReady: ((InMemoryTerminalViewport) -> Void)? {
        didSet {
            if onPhysicalViewportReady != nil { setNeedsLayout() }
        }
    }
    private(set) var awaitingPhysicalViewport = false
    public var authoritativeGrid: SessionClient.GridSize? {
        didSet {
            guard authoritativeGrid != oldValue else { return }
            awaitingPhysicalViewport = oldValue != nil && authoritativeGrid == nil
            if oldValue == nil && authoritativeGrid != nil { cancelPendingApplicationScroll() }
            updateTerminalGestureEnablement()
            setNeedsLayout()
        }
    }
    var reservesTopChromeSpace = false {
        didSet {
            guard reservesTopChromeSpace != oldValue else { return }
            if reservesTopChromeSpace {
                snapshotScrollView.onContentUpdate = { [weak self] in self?.refreshFirstLineClearance() }
                refreshFirstLineClearance()
            } else {
                snapshotScrollView.onContentUpdate = nil
            }
            setNeedsLayout()
        }
    }
    private var needsFirstLineClearance = true
    private(set) var firstLineClearanceReadCountForTesting = 0
    /// Retained panes keep receiving output offscreen. Their clearance is
    /// re-checked when they return to a window instead (IOS-6.42).
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        refreshFirstLineClearance()
    }

    /// Content can change without received output or a scrollbar callback:
    /// a width-only reflow, a terminal reset, or a paged snapshot. The
    /// snapshot scroll view therefore polls this while there is no
    /// scrollback (IOS-6.41); with scrollback no text is read.
    private func refreshFirstLineClearance() {
        guard reservesTopChromeSpace, window != nil else { return }
        let needsClearance: Bool
        if snapshotScrollView.hasScrollback {
            needsClearance = false
        } else {
            guard case .inMemory(let session) = terminalView.configuration.backend,
                  let text = session.readViewportText() else { return }
            firstLineClearanceReadCountForTesting += 1
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let columns = Int(terminalGridMetrics?.columns ?? UInt16.max)
            let fitsFirstRow = lines.first.map { TerminalCellWidth.estimate($0) <= columns } ?? true
            needsClearance = fitsFirstRow && lines.dropFirst().allSatisfy { $0.allSatisfy(\.isWhitespace) }
        }
        guard needsClearance != needsFirstLineClearance else { return }
        needsFirstLineClearance = needsClearance
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let canvas = snapshotCanvas
        snapshotScrollView.frame = bounds
        snapshotScrollView.topContentInset = topChromeInset(canvas: canvas)
        guard let grid = authoritativeGrid, let metrics = terminalGridMetrics, let canvas else {
            snapshotScrollView.configure(canvas: nil, nativeRowHeight: 0)
            confirmPhysicalViewportIfReady()
            return
        }
        snapshotScrollView.configure(
            canvas: canvas,
            nativeRowHeight: CGFloat(metrics.cellHeightPixels) / terminalView.contentScaleFactor,
            columns: grid.cols
        )
    }

    private var snapshotCanvas: TerminalSnapshotCanvas.Layout? {
        guard let grid = authoritativeGrid, let metrics = terminalGridMetrics else { return nil }
        return TerminalSnapshotCanvas.layout(
            grid: CGSize(width: Int(grid.cols), height: Int(grid.rows)),
            measuredGrid: CGSize(width: Int(metrics.columns), height: Int(metrics.rows)),
            measuredPixels: CGSize(width: Int(metrics.widthPixels), height: Int(metrics.heightPixels)),
            cellPixels: CGSize(width: Int(metrics.cellWidthPixels), height: Int(metrics.cellHeightPixels)),
            displayScale: terminalView.contentScaleFactor,
            container: bounds.size
        )
    }

    override public func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    // Protect a lone first line without leaving a gap above populated terminals.
    // UIKit supplies the chrome overlapping each pane, so lower split panes
    // do not reserve the navigation bar again.
    private func topChromeInset(canvas: TerminalSnapshotCanvas.Layout?) -> CGFloat {
        guard reservesTopChromeSpace, needsFirstLineClearance else { return 0 }
        let rowHeight = terminalGridMetrics.map {
            CGFloat($0.cellHeightPixels) / max(1, terminalView.contentScaleFactor)
                * (canvas?.scale ?? 1) * (canvas == nil ? 1 : snapshotScrollView.followerZoomScale)
        } ?? 0
        // Fullscreen Back occupies 44pt, with 12pt above and below it.
        let clearance = onBackRequested == nil ? rowHeight : max(rowHeight, 68)
        return min(safeAreaInsets.top + clearance, max(0, bounds.height - 1))
    }

    private func confirmPhysicalViewportIfReady() {
        // A queued native resize can still describe the follower canvas after
        // ownership flips. Confirm only the grid laid out at physical size.
        // Pixel comparison also covers fractional point changes that Ghostty
        // deduplicates without another resize notification.
        let scale = terminalView.contentScaleFactor
        let widthPixels = (bounds.width * scale).rounded(.down)
        let heightPixels = ((bounds.height - topChromeInset(canvas: nil)) * scale).rounded(.down)
        // Retained routes remove this callback while hidden. Keep their
        // confirmation pending until the route has somewhere to deliver it.
        guard awaitingPhysicalViewport, authoritativeGrid == nil,
              let onPhysicalViewportReady,
              widthPixels > 0, heightPixels > 0,
              let metrics = terminalGridMetrics,
              widthPixels == CGFloat(metrics.widthPixels),
              heightPixels == CGFloat(metrics.heightPixels),
              (terminalView.bounds.width * scale).rounded(.down) == widthPixels,
              (terminalView.bounds.height * scale).rounded(.down) == heightPixels else { return }
        awaitingPhysicalViewport = false
        onPhysicalViewportReady(InMemoryTerminalViewport(
            columns: metrics.columns, rows: metrics.rows,
            widthPixels: metrics.widthPixels, heightPixels: metrics.heightPixels,
            cellWidthPixels: metrics.cellWidthPixels, cellHeightPixels: metrics.cellHeightPixels
        ))
    }

    private(set) var isCommittedSoftwareInputEligible = false
    var agentCompletion: AgentCompletionModel? {
        get { terminalView.agentCompletion }
        set {
            guard terminalView.agentCompletion !== newValue else { return }
            terminalView.agentCompletion?.invalidateBoundary()
            terminalView.agentCompletion?.onInsertText = nil
            terminalView.agentCompletion = newValue
            newValue?.onInsertText = { [weak self] text in
                guard let self, self.isCommittedSoftwareInputEligible else { return }
                self.terminalView.stopHardwareArrowRepeat()
                self.terminalView.resetTextContext(notifyingInputSystem: true)
                self.storedCommittedSoftwareInput?.insertText(text)
            }
        }
    }

    @discardableResult
    func handleAgentCompletionControl(_ key: AgentCompletionKey) -> Bool {
        guard isCommittedSoftwareInputEligible else { return false }
        guard !isTrayShiftSelected, stickyControlActivation == .inactive else {
            agentCompletion?.invalidateBoundary()
            return false
        }
        return agentCompletion?.handleKey(key) == true
    }

    private(set) var storedCommittedSoftwareInput: TerminalPaneView.CommittedSoftwareInput?
    var committedSoftwareInput: TerminalPaneView.CommittedSoftwareInput? {
        get { storedCommittedSoftwareInput }
        set {
            let wasEligible = isCommittedSoftwareInputEligible
            if let newValue {
                storedCommittedSoftwareInput = .init(
                    insertText: { [weak self] text in
                        self?.cancelPendingApplicationScroll()
                        newValue.insertText(text)
                    },
                    insertControlByte: newValue.insertControlByte.map { insert in
                        { [weak self] byte in
                            self?.cancelPendingApplicationScroll()
                            insert(byte)
                        }
                    },
                    deleteBackward: { [weak self] in
                        self?.cancelPendingApplicationScroll()
                        newValue.deleteBackward()
                    }
                )
                isCommittedSoftwareInputEligible = true
                if !terminalView.isKeyboardInputEnabled { terminalView.isKeyboardInputEnabled = true }
            } else {
                if wasEligible {
                    agentCompletion?.invalidateBoundary()
                    resetStickyModifiers()
                    terminalView.resetTextContext()
                }
                isCommittedSoftwareInputEligible = false
                // The renderer resigns on every false assignment, even when
                // already disabled. Avoid another input-boundary callback.
                if terminalView.isKeyboardInputEnabled { terminalView.isKeyboardInputEnabled = false }
                terminalView.stopHardwareArrowRepeat()
                storedCommittedSoftwareInput = nil
            }
            guard wasEligible != isCommittedSoftwareInputEligible else { return }
            invalidateKeyCommands()
        }
    }
    var storedHardwareKeyboardCommands: [TerminalPaneView.HardwareKeyboardCommand] = []
    private(set) var keyCommandUpdateRequestCountForTesting = 0
    private(set) lazy var selectionController = TerminalSelectionController(
        surface: RealSurfaceProxy(surfaceProvider: { [weak self] in self?.terminalView.surface })
    )

    /// Called when the user taps the Paste action in the long-press
    /// menu — the SwiftUI layer wires this to `SessionClient.sendPaste`.
    public var onPasteRequested: (() -> Void)?
    /// Called on any touch that begins on the terminal surface — powers
    /// render-pace promotion back to `.full` (local scrolling renders
    /// without host output, so a finger on the surface must count as
    /// activity). Wired by the SwiftUI layer to `SessionClient.wakeRenderer()`.
    public var onUserInteraction: (() -> Void)?
    /// A deliberate app scroll is input. Keep attachment passive until a
    /// mouse-capturing follower receives this gesture, then wait for its owner grid.
    public var onApplicationScrollRequested: (() -> Void)? {
        didSet {
            if onApplicationScrollRequested == nil { cancelPendingApplicationScroll() }
            updateTerminalGestureEnablement()
        }
    }
    var pendingApplicationScroll = CGPoint.zero
    var applicationScrollLocation = CGPoint.zero
    var applicationScrollAttachmentID: UUID?
    var applicationScrollEnded = false
    var applicationScrollTask: Task<Void, Never>?
    #if DEBUG
    var diagnosticApplicationScrollRequests: UInt64 = 0
    var diagnosticApplicationScrollDeliveries: UInt64 = 0
    #endif

    private lazy var applicationScrollRecognizer: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleApplicationScroll(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        pan.isEnabled = false
        return pan
    }()

    /// Only fullscreen routes install this action; retained and embedded panes
    /// release it so a later drag cannot navigate a stale SwiftUI route.
    public var onBackRequested: (() -> Void)? {
        didSet {
            updateTerminalGestureEnablement()
            if (oldValue == nil) != (onBackRequested == nil) { setNeedsLayout() }
        }
    }
    private(set) var configuredFontSize: Float?
    private var observedFontSize: Float?
    var observedPinchScale: CGFloat = 1
    private var isObservingFontSize = false
    private var onObservedFontSizeChange: ((Float) -> Void)?

    public func configureFontSizeObservation(
        initialFontSize: Float?,
        onChange: ((Float) -> Void)?
    ) {
        let shouldObserve = initialFontSize != nil && onChange != nil
        if configuredFontSize != initialFontSize
            || isObservingFontSize != shouldObserve {
            configuredFontSize = initialFontSize
            observedFontSize = initialFontSize
            observedPinchScale = 1
        }
        isObservingFontSize = shouldObserve
        onObservedFontSizeChange = onChange
    }

    public var stickyControlActivation: StickyControlActivation {
        #if !targetEnvironment(macCatalyst)
        switch terminalView.stickyActivation(for: .ctrl) {
        case .inactive: .inactive
        case .armed: .armed
        case .locked: .locked
        }
        #else
        .inactive
        #endif
    }

    public func toggleStickyControlModifier() {
        agentCompletion?.invalidateBoundary()
        #if !targetEnvironment(macCatalyst)
        terminalView.toggleStickyModifier(.ctrl)
        #endif
    }

    public func resetStickyModifiers() {
        setTrayShiftSelected(false)
        #if !targetEnvironment(macCatalyst)
        terminalView.resetStickyModifiers()
        #endif
    }

    public private(set) var isTrayShiftSelected = false
    var onTrayShiftSelectionChange: ((Bool) -> Void)?

    public func toggleTrayShift() {
        guard isCommittedSoftwareInputEligible else { return }
        agentCompletion?.invalidateBoundary()
        setTrayShiftSelected(!isTrayShiftSelected)
    }

    private func setTrayShiftSelected(_ selected: Bool) {
        guard isTrayShiftSelected != selected else { return }
        isTrayShiftSelected = selected
        onTrayShiftSelectionChange?(selected)
    }

    public func setStickyControlActivationChangeHandler(
        _ handler: ((StickyControlActivation) -> Void)?
    ) {
        #if !targetEnvironment(macCatalyst)
        guard let handler else {
            terminalView.setStickyModifierChangeHandler(nil)
            return
        }
        terminalView.setStickyModifierChangeHandler { [weak self] in
            guard let self else { return }
            handler(self.stickyControlActivation)
        }
        #endif
    }

    /// UIKit queries `keyCommands` on every hardware key-down (plus menu and
    /// discoverability-HUD builds), so the built array is cached and only
    /// invalidated when the command signature actually changes. Fired
    /// commands resolve their `perform` closure by id from
    /// `storedHardwareKeyboardCommands` at handle time (see
    /// `matchingHardwareKeyboardCommand`), so a signature-equal update never
    /// needs a rebuilt array.
    private var cachedKeyCommands: [UIKeyCommand]?

    override public var keyCommands: [UIKeyCommand]? {
        let effectiveCommands = effectiveHardwareKeyboardCommands
        guard !effectiveCommands.isEmpty else { return nil }
        if let cachedKeyCommands { return cachedKeyCommands }
        let commands = effectiveCommands.map { command in
            let keyCommand = UIKeyCommand(
                title: command.title,
                image: nil,
                action: #selector(handleHardwareKeyboardCommand(_:)),
                input: command.input,
                modifierFlags: command.modifierFlags.appCommandModifiers,
                propertyList: command.id,
                alternates: [],
                discoverabilityTitle: command.title,
                attributes: [],
                state: .off
            )
            keyCommand.wantsPriorityOverSystemBehavior = true
            return keyCommand
        }
        cachedKeyCommands = commands
        return commands
    }

    /// Drops the cached `keyCommands` and asks UIKit to query them again.
    func invalidateKeyCommands() {
        cachedKeyCommands = nil
        keyCommandUpdateRequestCountForTesting += 1
        UIMenuSystem.main.setNeedsRebuild()
    }

    private(set) lazy var longPressMenu = UIEditMenuInteraction(delegate: self)
    private(set) lazy var selectionMenu = UIEditMenuInteraction(delegate: self)

    private lazy var anyTouchObserver: AnyTouchObserverGestureRecognizer = {
        let r = AnyTouchObserverGestureRecognizer()
        r.cancelsTouchesInView = false
        r.onTouchBegan = { [weak self] changesCursor in self?.handleAnyTouchBegan(changesCursor: changesCursor) }
        return r
    }()

    private(set) lazy var selectionPanRecognizer: UIPanGestureRecognizer = {
        let r = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionPan(_:)))
        r.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        r.maximumNumberOfTouches = 1
        r.isEnabled = false
        return r
    }()
    var selectionPanStartedInViewport = false
    private lazy var backSwipeRecognizer: UISwipeGestureRecognizer = {
        let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleBackSwipe(_:)))
        recognizer.direction = .right
        recognizer.numberOfTouchesRequired = 1
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        recognizer.delegate = self
        recognizer.isEnabled = false
        return recognizer
    }()

    /// Captures the most-recent long-press location so the menu's
    /// `Select` action can word-select at the original touch point even
    /// after the gesture has ended. Updated on `.began`.
    var lastLongPressPoint: CGPoint = .zero
    var longPressURL: URL?
    private(set) var terminalGridMetrics: TerminalGridMetrics?
    var openURL: (URL) -> Void = { _ in }
    var copyLink: (URL) -> Void = { UIPasteboard.general.string = $0.absoluteString }
    var linkContext: AnyHashable? {
        didSet {
            guard oldValue != linkContext else { return }
            invalidateLinkMenu()
        }
    }
    func detachBrowserControls() {
        openURL = { _ in }
        linkContext = nil
        // Even a context-free caller can hold actions capturing its old route.
        invalidateLinkMenu()
    }

    private func invalidateLinkMenu() {
        longPressURL = nil
        longPressMenuGeneration &+= 1
        pendingPasteRefocusGeneration = nil
        completedLongPressMenuDismissalGeneration = nil
        longPressMenu.dismissMenu()
    }

    var probingLink = false
    var probedLink: String?
    /// Paste and edit-menu dismissal are independent UIKit callbacks whose
    /// relative ordering is not part of our contract. Pair them by long-press
    /// menu generation and refocus only after both have happened.
    var longPressMenuGeneration: UInt = 0
    var pendingPasteRefocusGeneration: UInt?
    var completedLongPressMenuDismissalGeneration: UInt?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false

        clipsToBounds = true
        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.delegate = self
        terminalView.softwareInputDelegate = self
        terminalView.hardwareInputDelegate = self
        terminalView.isKeyboardInputEnabled = false
        #if !targetEnvironment(macCatalyst)
        // libghostty's hidden stock accessory installs its own sticky-state
        // observer the first time it is created. Initialize it before the host
        // installs its observer so later ordinary text cannot replace ours.
        _ = terminalView.inputAccessoryView
        #endif
        terminalView.showsInputAccessory = false
        addSubview(snapshotScrollView)
        #if !targetEnvironment(macCatalyst)
        terminalView.gestureRecognizers?
            .compactMap { $0 as? UIPinchGestureRecognizer }
            .first?
            .addTarget(self, action: #selector(observeTerminalPinch(_:)))
        #endif

        configureTerminalPanRecognizersForIndirectScrolling()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFocusKeyboardInputTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        addInteraction(longPressMenu)
        addInteraction(selectionMenu)
        addGestureRecognizer(selectionPanRecognizer)
        snapshotScrollView.panGestureRecognizer.require(toFail: selectionPanRecognizer)
        addGestureRecognizer(backSwipeRecognizer)
        snapshotScrollView.panGestureRecognizer.require(toFail: backSwipeRecognizer)
        addGestureRecognizer(applicationScrollRecognizer)
        applicationScrollRecognizer.require(toFail: selectionPanRecognizer)
        applicationScrollRecognizer.require(toFail: backSwipeRecognizer)
        snapshotScrollView.panGestureRecognizer.require(toFail: applicationScrollRecognizer)
        for pan in terminalView.gestureRecognizers?.compactMap({ $0 as? UIPanGestureRecognizer }) ?? [] {
            pan.require(toFail: applicationScrollRecognizer)
            if pan.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)) {
                pan.require(toFail: backSwipeRecognizer)
            }
        }
        addGestureRecognizer(anyTouchObserver)
    }

    #if !targetEnvironment(macCatalyst)
    /// Observes libghostty's own pinch recognizer without replacing it. The
    /// step calculation mirrors libghostty-spm so the persisted value follows
    /// the font actions that its recognizer sends to the live surface.
    @objc private func observeTerminalPinch(_ gesture: UIPinchGestureRecognizer) {
        guard isObservingFontSize, observedFontSize != nil else { return }

        switch gesture.state {
        case .began:
            observedPinchScale = gesture.scale
        case .changed:
            let delta = gesture.scale - observedPinchScale
            let steps = Int(delta / 0.1)
            guard steps != 0 else { return }
            observedPinchScale += CGFloat(steps) * 0.1
            applyObservedFontSizeSteps(steps)
        case .ended, .cancelled, .failed:
            observedPinchScale = 1
        default:
            break
        }
    }
    #endif

    func applyObservedFontSizeSteps(_ steps: Int) {
        guard isObservingFontSize, let observedFontSize else { return }
        let adjusted = TerminalFontSizeAdjustment.apply(
            steps: steps,
            to: observedFontSize
        )
        guard adjusted != observedFontSize else { return }
        // Advance the configured baseline before publishing. SwiftUI echoes
        // the preference through `updateUIView`; treating that echo as an
        // external reconfiguration would reset the cumulative pinch scale
        // while libghostty's recognizer is still in the same gesture.
        configuredFontSize = adjusted
        self.observedFontSize = adjusted
        onObservedFontSizeChange?(adjusted)
    }

    private func configureTerminalPanRecognizersForIndirectScrolling() {
        terminalView.gestureRecognizers?
            .compactMap { $0 as? UIPanGestureRecognizer }
            .forEach { recognizer in
                recognizer.allowedScrollTypesMask = [.continuous, .discrete]
                if recognizer.delegate == nil {
                    recognizer.delegate = terminalView
                }
            }
    }

    @objc private func handleFocusKeyboardInputTap(_ recognizer: UITapGestureRecognizer) {
        guard acceptsTerminalInput(at: recognizer.location(in: self)) else { return }
        _ = focusKeyboardInput()
    }

    func acceptsTerminalInput(at point: CGPoint) -> Bool {
        snapshotScrollView.frame.contains(point)
            && point.y >= snapshotScrollView.frame.minY + snapshotScrollView.topContentInset
    }

    @discardableResult
    func focusKeyboardInput() -> Bool {
        terminalView.becomeFirstResponder()
    }

    /// Masked pans whose `allowedTouchTypes` were narrowed on entering
    /// selection mode, with their prior values, so exit restores exactly
    /// what libghostty/setup installed.
    var selectionModeSavedTouchTypes: [(UIPanGestureRecognizer, [NSNumber])] = []
    private var suppressedTerminalGestures: [ObjectIdentifier: Bool] = [:]

    /// Selection and the checkpoint canvas can both suppress pinch. Restore
    /// each original state only after both restrictions have been released.
    func updateTerminalGestureEnablement() {
        backSwipeRecognizer.isEnabled = onBackRequested != nil && !selectionController.isActive
        applicationScrollRecognizer.isEnabled = onApplicationScrollRequested != nil && !selectionController.isActive
        if selectionController.isActive { cancelPendingApplicationScroll() }
        snapshotScrollView.followerPinchGesture.isEnabled = authoritativeGrid != nil && !selectionPanRecognizer.isEnabled
        for recognizer in terminalView.gestureRecognizers ?? [] {
            let scrollPan = (recognizer as? UIPanGestureRecognizer).map {
                !$0.allowedScrollTypesMask.isEmpty
            } ?? false
            let suppressed = (selectionPanRecognizer.isEnabled && !scrollPan)
                || (authoritativeGrid != nil && (recognizer is UIPinchGestureRecognizer || scrollPan))
            let id = ObjectIdentifier(recognizer)
            if suppressed {
                if suppressedTerminalGestures[id] == nil {
                    suppressedTerminalGestures[id] = recognizer.isEnabled
                }
                recognizer.isEnabled = false
            } else if let wasEnabled = suppressedTerminalGestures.removeValue(forKey: id) {
                recognizer.isEnabled = wasEnabled
            }
        }
    }

    func handleAnyTouchBegan(changesCursor: Bool) {
        // A finger tap only changes keyboard focus. Keep the initial boundary
        // so the first percent key can open completion at an empty prompt.
        if changesCursor || agentCompletion?.isActive == true {
            agentCompletion?.invalidateBoundary()
        }
        onUserInteraction?()
    }

    public func terminalView(_: UITerminalView, insertText text: String) -> Bool {
        guard isCommittedSoftwareInputEligible else { return true }
        guard let insertText = storedCommittedSoftwareInput?.insertText else { return false }
        insertText(text)
        return true
    }

    public func terminalViewDeleteBackward(_: UITerminalView) -> Bool {
        guard isCommittedSoftwareInputEligible else { return true }
        guard let deleteBackward = storedCommittedSoftwareInput?.deleteBackward else { return false }
        deleteBackward()
        return true
    }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleHardwareKeyboardCommand(_:)),
           let command = sender as? UIKeyCommand {
            return matchingHardwareKeyboardCommand(for: command) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === applicationScrollRecognizer {
            let velocity = applicationScrollRecognizer.velocity(in: self)
            return onApplicationScrollRequested != nil && controlAttachmentID != nil
                && authoritativeGrid != nil && !selectionController.isActive
                && snapshotScrollView.followerZoomScale == 1
                && acceptsTerminalInput(at: applicationScrollRecognizer.location(in: self))
                && terminalView.surface?.isMouseCaptured == true
                && abs(velocity.y) >= abs(velocity.x)
        }
        guard gestureRecognizer === backSwipeRecognizer else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return onBackRequested != nil && !selectionController.isActive
            && snapshotScrollView.followerZoomScale == 1
    }

    @objc func handleBackSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended, onBackRequested != nil,
              !selectionController.isActive, snapshotScrollView.followerZoomScale == 1 else { return }
        onBackRequested?()
    }

}

extension TerminalInputContainerView: UIGestureRecognizerDelegate { }

extension TerminalInputContainerView: TerminalSurfaceOpenURLDelegate, TerminalSurfaceHoverLinkDelegate {
    public func terminalDidRequestOpenURL(_ value: String, kind: TerminalOpenURLKind) {
        guard let url = TerminalLinkResolver.webURL(value) else { return }
        openURL(url)
    }

    public func terminalDidUpdateHoverLink(_ value: String?) {
        if probingLink { probedLink = value }
    }
}

extension TerminalInputContainerView: TerminalSurfaceLifecycleDelegate {
    public func terminalDidAttachSurface(_ surface: TerminalSurface) {
        refreshFirstLineClearance()
        setNeedsLayout()
    }

    public func terminalDidDetachSurface() {
        needsFirstLineClearance = true
        cancelActiveSelectionIfAny()
        longPressURL = nil
        terminalGridMetrics = nil
        longPressMenuGeneration &+= 1
        pendingPasteRefocusGeneration = nil
        completedLongPressMenuDismissalGeneration = nil
        longPressMenu.dismissMenu()
        selectionMenu.dismissMenu()
    }
}

extension TerminalInputContainerView: TerminalSurfaceScrollbarDelegate {
    public func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        snapshotScrollView.updateScrollbar(scrollbar)
        refreshFirstLineClearance()
    }
}

extension TerminalInputContainerView: TerminalSurfaceGridResizeDelegate {
    public func terminalDidResize(_ size: TerminalGridMetrics) {
        terminalGridMetrics = size
        setNeedsLayout()
        confirmPhysicalViewportIfReady()
    }
}

/// Observes touch-begin without claiming the gesture: reports, then
/// immediately fails so libghostty's pan/pinch and the selection
/// recognizers proceed untouched. Powers render-pace promotion —
/// local scrolling renders without host output, so a finger on the
/// surface must count as activity.
final class AnyTouchObserverGestureRecognizer: UIGestureRecognizer {
    var onTouchBegan: ((Bool) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchBegan?(touches.contains { $0.type == .indirectPointer })
        state = .failed
    }
}

extension UIKeyModifierFlags {
    var appCommandModifiers: UIKeyModifierFlags {
        intersection([.shift, .control, .alternate, .command])
    }
}

#endif
