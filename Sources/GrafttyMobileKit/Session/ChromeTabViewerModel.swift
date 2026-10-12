import Foundation
import Observation
import GrafttyProtocol
import GrafttyRemoteClient
#if canImport(UIKit)
import UIKit
#endif

@MainActor @Observable
final class ChromeTabViewerModel {
    var state = ChromeTabState()
    #if canImport(UIKit)
    var image: UIImage?
    #endif
    var error: String?
    var initialLaunchError: String?
    private var pendingCount = 0
    private var inputCount = 0
    var busy: Bool { inputCount > 0 }
    private var client: ChromeTabClient?
    private var generation = UUID()
    private var requestOrdinal = 0
    private var lastAppliedOrdinal = 0
    private var frameSequence: UInt64?
    private var frameTabID: String?

    func run(target: String, initialLaunch: ChromeTabInitialLaunch?, onLaunch: () -> Void,
             makeDriver: () async throws -> any ChromeTabChannelDriver) async {
        close()
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
            defer { driver.close(); if generation == epoch { client = nil; clearImage() } }
            let listed = await send(.list, target: target)
            guard listed, !Task.isCancelled, generation == epoch else { return }
            if let initialLaunch {
                let launched = await send(initialLaunch.action, target: target)
                guard !Task.isCancelled, generation == epoch else { return }
                if launched, initialLaunch.accept(.init(state: state)) { onLaunch() }
                else { initialLaunchError = error ?? "Could not start sign-in. Retry or select an existing tab." }
            } else if let first = state.tabs.first?.id { await send(.select(tabID: first), target: target) }
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
        guard let client, !Task.isCancelled else { return false }
        if polling, pendingCount > 0 { return false }
        let epoch = generation
        requestOrdinal += 1
        let ordinal = requestOrdinal
        pendingCount += 1
        if !polling { inputCount += 1 }
        defer { if generation == epoch { pendingCount -= 1; if !polling { inputCount -= 1 } } }
        do {
            let reply = try await client.send(.init(target: target, action: action))
            guard !Task.isCancelled, generation == epoch else { return false }
            guard ordinal >= lastAppliedOrdinal else { return reply.error == nil }
            lastAppliedOrdinal = ordinal
            error = reply.error
            guard let next = reply.state else { clearImage(); return false }
            state = next
            updateImage(next)
            return reply.error == nil
        } catch ChromeTabClient.Failure.queueFull {
            if generation == epoch { error = "Chrome input queue is full. Try sending again." }
            return false
        } catch {
            if generation == epoch { self.error = "Chrome connection ended. Close and reopen to reconnect."; clearImage(); client.cancel(); self.client = nil }
            return false
        }
    }

    private func clearImage() {
        #if canImport(UIKit)
        image = nil
        #endif
    }

    private func updateImage(_ next: ChromeTabState) {
        #if canImport(UIKit)
        if let frame = next.frame, frame.tabID == next.selectedTabID,
           frame.jpeg.count <= ChromeTabFrame.maximumJPEGBytes {
            if frame.sequence != frameSequence || frame.tabID != frameTabID {
                if let decoded = UIImage(data: frame.jpeg), decoded.size.width <= 2048, decoded.size.height <= 2048 {
                    image = decoded; frameSequence = frame.sequence; frameTabID = frame.tabID
                }
            }
        } else { clearImage(); frameSequence = nil; frameTabID = nil }
        #endif
    }

    func close() {
        generation = UUID(); client?.cancel(); client = nil
        clearImage(); state = .init(); pendingCount = 0; inputCount = 0; error = nil; initialLaunchError = nil
        frameSequence = nil; frameTabID = nil; requestOrdinal = 0; lastAppliedOrdinal = 0
    }
}

