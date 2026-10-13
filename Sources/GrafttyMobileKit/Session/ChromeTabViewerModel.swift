import Foundation
import Observation
import GrafttyProtocol
import GrafttyRemoteClient
#if canImport(UIKit)
import UIKit
#endif

struct ChromeTabViewportSize: Equatable {
    let width: Int
    let height: Int
    var cgSize: CGSize { CGSize(width: width, height: height) }
    static func fitting(_ size: CGSize) -> Self? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let width = Int(min(1024, max(320, size.width.rounded())))
        let height = min(Int(min(1600, max(240, size.height.rounded()))), 1_500_000 / width)
        return Self(width: width, height: height)
    }
}

@MainActor @Observable
final class ChromeTabViewerModel {
    var state = ChromeTabState()
    #if canImport(UIKit)
    var image: UIImage?
    #endif
    var error: String?
    var initialLaunchError: String?
    var keyboardPresented = false
    private(set) var isConnected = false
    private(set) var frameInputEnabled = false
    private(set) var frameSize = CGSize(width: ChromeTabFrame.viewportWidth, height: ChromeTabFrame.viewportHeight)
    private(set) var desiredViewport: ChromeTabViewportSize?
    private var resizeTask: Task<Void, Never>?
    private var pendingSelectionOrdinal: Int?
    private var pendingCount = 0
    private var inputCount = 0
    var busy: Bool { inputCount > 0 }
    private var client: ChromeTabClient?
    private var generation = UUID()
    private var requestOrdinal = 0
    private var lastAppliedOrdinal = 0
    private var frameSequence: UInt64?
    private var frameTabID: String?
    private var reconnectTabID: String?

    func toggleKeyboard() { keyboardPresented.toggle() }

    func requestViewport(_ size: CGSize, target: String) {
        guard let next = ChromeTabViewportSize.fitting(size), next != desiredViewport else { return }
        desiredViewport = next
        if state.viewportID != nil, viewportSize != next || resizeTask != nil { invalidateFrame() }
        scheduleResize(target: target)
    }

    private var viewportSize: ChromeTabViewportSize? {
        guard let width = state.width, let height = state.height else { return nil }
        return ChromeTabViewportSize(width: width, height: height)
    }

    private func scheduleResize(target: String) {
        guard resizeTask == nil, isConnected, pendingSelectionOrdinal == nil, state.viewportID != nil,
              let selected = state.selectedTabID, let desiredViewport, viewportSize != desiredViewport else { return }
        let epoch = generation
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, self.generation == epoch else { return }
            defer {
                if self.generation == epoch {
                    self.resizeTask = nil
                    if self.state.selectedTabID != selected { self.scheduleResize(target: target) }
                }
            }
            while !Task.isCancelled, self.generation == epoch, self.isConnected,
                  self.pendingSelectionOrdinal == nil, self.state.selectedTabID == selected,
                  let wanted = self.desiredViewport, self.viewportSize != wanted {
                self.invalidateFrame()
                guard await self.send(.viewport(tabID: selected, width: wanted.width, height: wanted.height), target: target),
                      self.generation == epoch else { return }
            }
        }
    }

    func run(target: String, initialLaunch: ChromeTabInitialLaunch?, onLaunch: () -> Void,
             makeDriver: () async throws -> any ChromeTabChannelDriver) async {
        let selectedBeforeReconnect = state.selectedTabID ?? reconnectTabID
        close()
        reconnectTabID = selectedBeforeReconnect
        let epoch = generation
        do {
            let driver = try await makeDriver()
            guard !Task.isCancelled, generation == epoch else { driver.close(); return }
            let connectionClient = ChromeTabClient(driver: driver)
            client = connectionClient
            do { try await connectionClient.open() }
            catch {
                driver.close()
                if generation == epoch, !Task.isCancelled {
                    self.error = "This host does not support dedicated Chrome tabs. Update the Mac app to use the prototype."
                    client = nil
                }
                return
            }
            guard !Task.isCancelled, generation == epoch else { driver.close(); return }
            isConnected = true
            defer {
                driver.close()
                if generation == epoch { client = nil; isConnected = false; invalidateFrame() }
            }
            let listed = await send(.list, target: target)
            guard listed, !Task.isCancelled, generation == epoch else { return }
            if let initialLaunch, case .launchOffer = initialLaunch.action {
                let launched = await send(initialLaunch.action, target: target)
                guard !Task.isCancelled, generation == epoch else { return }
                if launched, initialLaunch.accept(.init(state: state)) { onLaunch() }
                else { initialLaunchError = error ?? "Could not start sign-in. Retry or select an existing tab." }
            } else if let selected = state.tabs.first(where: { $0.id == (selectedBeforeReconnect ?? initialLaunch?.action.tabID) })?.id ?? state.tabs.first?.id {
                if await send(.select(tabID: selected), target: target), let initialLaunch, initialLaunch.accept(.init(state: state)) { onLaunch() }
            }
            while !Task.isCancelled, generation == epoch {
                try await Task.sleep(for: .milliseconds(250))
                if pendingCount == 0 {
                    await send(state.selectedTabID.map { .frame(tabID: $0) } ?? .list, target: target, polling: true)
                }
            }
        } catch {
            if !Task.isCancelled, generation == epoch { self.error = String(describing: error) }
        }
    }

    @discardableResult
    func send(_ action: ChromeTabAction, target: String, polling: Bool = false) async -> Bool {
        guard let client, isConnected, !Task.isCancelled else {
            if !polling, !Task.isCancelled { error = "Chrome is connecting. Try again." }
            return false
        }
        switch action {
        case .tap, .scroll:
            guard frameInputEnabled else { return false }
        default: break
        }
        if polling, pendingCount > 0 { return false }
        let epoch = generation
        requestOrdinal += 1
        let ordinal = requestOrdinal
        switch action {
        case .select, .launch, .launchOffer:
            pendingSelectionOrdinal = ordinal
            invalidateFrame()
        default: break
        }
        pendingCount += 1
        if !polling { inputCount += 1 }
        defer {
            if generation == epoch {
                pendingCount -= 1
                if !polling { inputCount -= 1 }
                if pendingSelectionOrdinal == ordinal { pendingSelectionOrdinal = nil; scheduleResize(target: target) }
            }
        }
        do {
            let reply = try await client.send(.init(target: target, action: action))
            guard !Task.isCancelled, generation == epoch else { return false }
            guard ordinal >= lastAppliedOrdinal else { return reply.error == nil }
            lastAppliedOrdinal = ordinal
            error = reply.error
            if pendingSelectionOrdinal == ordinal { pendingSelectionOrdinal = nil }
            guard let next = reply.state else { invalidateFrame(); return false }
            state = next
            if reply.error == nil, let selected = next.selectedTabID { reconnectTabID = selected }
            updateImage(next)
            scheduleResize(target: target)
            return reply.error == nil
        } catch ChromeTabClient.Failure.queueFull {
            if generation == epoch { error = "Chrome input queue is full. Try sending again." }
            return false
        } catch {
            if generation == epoch {
                self.error = "Chrome connection ended. Close and reopen to reconnect."
                invalidateFrame(); isConnected = false; client.cancel(); self.client = nil
            }
            return false
        }
    }

    private func invalidateFrame() {
        frameInputEnabled = false
        frameSequence = nil; frameTabID = nil
        #if canImport(UIKit)
        image = nil
        #endif
    }

    private func updateImage(_ next: ChromeTabState) {
        guard pendingSelectionOrdinal == nil, let frame = next.frame, frame.tabID == next.selectedTabID,
              frame.jpeg.count <= ChromeTabFrame.maximumJPEGBytes else { invalidateFrame(); return }
        let width = frame.width ?? ChromeTabFrame.viewportWidth
        let height = frame.height ?? ChromeTabFrame.viewportHeight
        guard (320...1024).contains(width), (240...1600).contains(height), width * height <= 1_500_000 else { invalidateFrame(); return }
        let dimensions = ChromeTabViewportSize(width: width, height: height)
        if let viewportID = next.viewportID {
            guard frame.viewportID == viewportID, next.width == width, next.height == height,
                  desiredViewport == nil || desiredViewport == dimensions else { invalidateFrame(); return }
        } else {
            guard frame.viewportID == nil, width == ChromeTabFrame.viewportWidth,
                  height == ChromeTabFrame.viewportHeight else { invalidateFrame(); return }
        }
        #if canImport(UIKit)
        if frame.sequence != frameSequence || frame.tabID != frameTabID || frameSize != dimensions.cgSize {
            guard let decoded = UIImage(data: frame.jpeg),
                  decoded.size.width == CGFloat(width), decoded.size.height == CGFloat(height) else { invalidateFrame(); return }
            image = decoded
        }
        #endif
        frameSize = dimensions.cgSize
        frameSequence = frame.sequence; frameTabID = frame.tabID
        frameInputEnabled = true
    }

    func suspend() {
        let retained = state
        let selected = state.selectedTabID ?? reconnectTabID
        close()
        state = retained
        reconnectTabID = selected
    }

    func close() {
        reconnectTabID = nil
        generation = UUID(); resizeTask?.cancel(); resizeTask = nil
        client?.cancel(); client = nil; isConnected = false; pendingSelectionOrdinal = nil
        invalidateFrame(); state = .init(); pendingCount = 0; inputCount = 0
        error = nil; initialLaunchError = nil; keyboardPresented = false
        frameSize = CGSize(width: ChromeTabFrame.viewportWidth, height: ChromeTabFrame.viewportHeight)
        requestOrdinal = 0; lastAppliedOrdinal = 0
    }
}

