#if os(macOS)
import Foundation
import Darwin
import CryptoKit
import GrafttyProtocol
import ImageIO

/// Launches only Graftty's isolated headless profile. Never attaches to personal Chrome.
public actor DedicatedChromeBackend: ChromeTabBackend {
    public enum Failure: Error { case unavailable, launchFailed, disconnected, busy, timeout, invalidTab, tooManyTabs, protocolError(String) }
    private let profile: URL
    private let portOwner = UUID()
    private var process: Process?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var nextID = 0
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
        var send: Task<Void, Never>?
        var offer: (id: UUID, url: String)?
    }
    private var pending: [Int: Pending] = [:]
    private var offerLaunches: ChromeOfferLaunchLedger
    private var selectedTabID: String?
    private var sessionID: String?
    private var canGoBack: Bool?
    private var canGoForward: Bool?
    private var navigationHistoryDirty = false
    private var latestFrame: ChromeTabFrame?
    private var viewportWidth = ChromeTabFrame.viewportWidth
    private var viewportHeight = ChromeTabFrame.viewportHeight
    private var viewportID: UInt64 = 0
    private var sequence: UInt64 = 0
    /// A bounded CDP source JPEG may exceed the viewer limit before recompression.
    private static let maximumCaptureJPEGBytes = 1_500_000
    private var busy = false
    private var authorization: (@Sendable () async -> Bool)?

    public init(worktreePath: String) {
        let hash = SHA256.hash(data: Data(worktreePath.utf8)).map { String(format: "%02x", $0) }.joined()
        profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty/ChromeMux/\(hash)", isDirectory: true)
        offerLaunches = ChromeOfferLaunchLedger(storageURL: profile.appendingPathComponent("GrafttyOfferLaunches.json"))
    }

    init(testProfile: URL) {
        profile = testProfile
        offerLaunches = ChromeOfferLaunchLedger(storageURL: profile.appendingPathComponent("GrafttyOfferLaunches.json"))
    }

    func shutdownForTesting() async {
        await stopCapture()
        if let socket { lostSocket(socket) }
        if process?.isRunning == true { process?.terminate() }
        for _ in 0..<100 {
            if process?.isRunning != true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        process = nil
        ChromeDebugPortRegistry.shared.unregister(owner: portOwner)
    }

    func evaluateForTesting(_ expression: String) async throws -> String {
        // Internal test seam. No remote command accepts JavaScript or CDP methods.
        let result = try await call("Runtime.evaluate", params: ["expression": expression, "returnByValue": true], session: sessionID, checkAuthorization: false)
        return String(describing: (result["result"] as? [String: Any])?["value"] ?? "")
    }

    public func perform(_ action: ChromeTabAction, authorize: @escaping @Sendable () async -> Bool) async throws -> ChromeTabState {
        guard action.isValid else { throw Failure.protocolError("Invalid Chrome input.") }
        guard !busy else { throw Failure.busy }
        busy = true
        authorization = authorize
        defer { busy = false; authorization = nil }
        try Task.checkCancellation()
        try await connect()
        var tabs = try await listTabs()
        switch action {
        case .launch(let url):
            guard tabs.count < 32 else { throw Failure.tooManyTabs }
            let result = try await call("Target.createTarget", params: ["url": url])
            guard let id = result["targetId"] as? String else { throw Failure.launchFailed }
            try await select(id, tabs: try await listTabs())
        case .launchOffer(let offerID, let url):
            if let id = try offerLaunches.tab(for: offerID, url: url) {
                try await select(id, tabs: tabs)
            } else {
                guard tabs.count < 32 else { throw Failure.tooManyTabs }
                let result = try await call("Target.createTarget", params: ["url": url], offer: (offerID, url))
                guard let id = result["targetId"] as? String else { throw Failure.launchFailed }
                try await select(id, tabs: try await listTabs())
            }
        case .select(let id): try await select(id, tabs: tabs)
        case .list: break
        case .frame(let id):
            if !tabs.contains(where: { $0.id == id }) { await stopCapture() }
            else { try requireSelected(id, tabs: tabs) }
        case .tap(let id, let x, let y):
            try requireInputReady(id, tabs: tabs)
            let point: [String: Any] = ["x": x * Double(viewportWidth), "y": y * Double(viewportHeight), "button": "left", "clickCount": 1]
            var down = point; down["type"] = "mousePressed"
            var up = point; up["type"] = "mouseReleased"
            _ = try await call("Input.dispatchMouseEvent", params: down, session: sessionID)
            _ = try await call("Input.dispatchMouseEvent", params: up, session: sessionID)
        case .scroll(let id, let x, let y, let dx, let dy):
            try requireInputReady(id, tabs: tabs)
            _ = try await call("Input.dispatchMouseEvent", params: ["type": "mouseWheel", "x": x * Double(viewportWidth), "y": y * Double(viewportHeight), "deltaX": dx, "deltaY": dy], session: sessionID)
        case .text(let id, let text):
            try requireInputReady(id, tabs: tabs)
            _ = try await call("Input.insertText", params: ["text": text], session: sessionID)
        case .key(let id, let key):
            try requireInputReady(id, tabs: tabs)
            let values: (String, String, Int)
            switch key {
            case .enter: values = ("Enter", "Enter", 13)
            case .tab: values = ("Tab", "Tab", 9)
            case .backspace: values = ("Backspace", "Backspace", 8)
            case .escape: values = ("Escape", "Escape", 27)
            }
            _ = try await call("Input.dispatchKeyEvent", params: ["type": "keyDown", "key": values.0, "code": values.1, "windowsVirtualKeyCode": values.2, "text": key == .enter ? "\r" : ""], session: sessionID)
            _ = try await call("Input.dispatchKeyEvent", params: ["type": "keyUp", "key": values.0, "code": values.1, "windowsVirtualKeyCode": values.2], session: sessionID)
        case .back(let id):
            try requireSelected(id, tabs: tabs)
            try await navigateHistory(offset: -1)
        case .forward(let id):
            try requireSelected(id, tabs: tabs)
            try await navigateHistory(offset: 1)
        case .reload(let id):
            try requireSelected(id, tabs: tabs)
            _ = try await call("Page.reload", session: sessionID)
            navigationHistoryDirty = true
        case .viewport(let id, let width, let height):
            try requireSelected(id, tabs: tabs)
            await stopCapture()
            try Task.checkCancellation()
            viewportWidth = width; viewportHeight = height; viewportID &+= 1
            // A new attachment excludes late frames even when returning to a previous size.
            try await select(id, tabs: tabs)
        }
        tabs = try await listTabs()
        if let id = selectedTabID, !tabs.contains(where: { $0.id == id }) { await stopCapture() }
        try await refreshNavigationAvailability()
        return .init(tabs: tabs, selectedTabID: selectedTabID, frame: latestFrame,
                     canGoBack: canGoBack, canGoForward: canGoForward,
                     width: selectedTabID == nil ? nil : viewportWidth,
                     height: selectedTabID == nil ? nil : viewportHeight,
                     viewportID: selectedTabID == nil ? nil : viewportID)
    }

    private func requireSelected(_ id: String, tabs: [ChromeTab]) throws {
        guard id == selectedTabID, sessionID != nil, tabs.contains(where: { $0.id == id }) else { throw Failure.invalidTab }
    }

    private func requireInputReady(_ id: String, tabs: [ChromeTab]) throws {
        try requireSelected(id, tabs: tabs)
        guard latestFrame?.viewportID == viewportID,
              latestFrame?.width == viewportWidth, latestFrame?.height == viewportHeight else {
            throw Failure.protocolError("Waiting for a fresh Chrome viewport frame.")
        }
    }

    private func navigationHistory(session: String) async throws -> (index: Int, entries: [[String: Any]]) {
        let result = try await call("Page.getNavigationHistory", session: session)
        guard session == sessionID, let index = result["currentIndex"] as? Int,
              let entries = result["entries"] as? [[String: Any]], entries.indices.contains(index) else {
            throw Failure.protocolError("Chrome navigation history is unavailable.")
        }
        return (index, entries)
    }

    private func navigateHistory(offset: Int) async throws {
        guard let session = sessionID else { throw Failure.invalidTab }
        let history = try await navigationHistory(session: session)
        let destination = history.index + offset
        guard history.entries.indices.contains(destination) else { return }
        guard let entryID = history.entries[destination]["id"] as? Int else {
            throw Failure.protocolError("Chrome navigation history is unavailable.")
        }
        _ = try await call("Page.navigateToHistoryEntry", params: ["entryId": entryID], session: session)
        navigationHistoryDirty = true
    }

    private func refreshNavigationAvailability() async throws {
        guard navigationHistoryDirty, let session = sessionID else { return }
        // Events arriving while this read is suspended must schedule a later refresh.
        navigationHistoryDirty = false
        do {
            let history = try await navigationHistory(session: session)
            canGoBack = history.index > 0
            canGoForward = history.index + 1 < history.entries.count
        } catch {
            navigationHistoryDirty = sessionID != nil
            // A document swap can briefly leave Page history unavailable after
            // a successful navigation. Refresh on the next poll, but keep
            // ownership and cancellation failures visible.
            guard case Failure.protocolError("Not attached to an active page") = error,
                  session == sessionID, socket?.state == .running else { throw error }
            try Task.checkCancellation()
            guard let authorization, await authorization() else {
                throw Failure.protocolError("Pane ownership changed.")
            }
            try Task.checkCancellation()
            guard session == sessionID, socket?.state == .running else { throw error }
        }
    }

    public func stopCapture() async {
        let oldSession = sessionID
        sessionID = nil; selectedTabID = nil; latestFrame = nil
        canGoBack = nil; canGoForward = nil; navigationHistoryDirty = false
        if let oldSession {
            // Cleanup must survive cancellation of the viewer RPC that triggered it.
            await Task { [self] in
                _ = try? await call("Page.stopScreencast", session: oldSession, checkAuthorization: false)
                _ = try? await call("Target.detachFromTarget", params: ["sessionId": oldSession], checkAuthorization: false)
            }.value
        }
    }

    private func select(_ id: String, tabs: [ChromeTab]) async throws {
        guard tabs.contains(where: { $0.id == id }) else { throw Failure.invalidTab }
        if id == selectedTabID, sessionID != nil { return }
        await stopCapture()
        let attached = try await call("Target.attachToTarget", params: ["targetId": id, "flatten": true])
        guard let session = attached["sessionId"] as? String else { throw Failure.invalidTab }
        sessionID = session; selectedTabID = id
        do {
            _ = try await call("Target.activateTarget", params: ["targetId": id])
            _ = try await call("Emulation.setDeviceMetricsOverride", params: ["width": viewportWidth, "height": viewportHeight, "deviceScaleFactor": 1, "mobile": false], session: session)
            _ = try await call("Page.enable", session: session)
            navigationHistoryDirty = true
            _ = try await call("Page.startScreencast", params: ["format": "jpeg", "quality": 65, "maxWidth": viewportWidth, "maxHeight": viewportHeight, "everyNthFrame": 1, "maxFramesInFlight": 1, "sendLastFrame": true], session: session)
        } catch { await stopCapture(); throw error }
    }

    private func listTabs() async throws -> [ChromeTab] {
        let result = try await call("Target.getTargets")
        let targets = result["targetInfos"] as? [[String: Any]] ?? []
        return targets.filter { $0["type"] as? String == "page" }.prefix(32).compactMap {
            guard let id = $0["targetId"] as? String, id.utf8.count <= 128 else { return nil }
            let rawURL = $0["url"] as? String ?? ""
            // Reserve wire space for the JPEG and JSON escaping across all 32 tabs.
            let urlLimit = id == selectedTabID ? 8192 : 2048
            var bytes = Data(rawURL.utf8.prefix(urlLimit))
            // Dropping an incomplete final scalar preserves the byte limit and URL text.
            while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            return .init(id: id, title: Self.boundedMetadata($0["title"] as? String ?? "", bytes: 256),
                         url: String(decoding: bytes, as: UTF8.self), urlTruncated: rawURL.utf8.count > urlLimit)
        }.sorted { $0.id < $1.id }
    }

    private static func boundedMetadata(_ value: String, bytes: Int) -> String {
        let clean = String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
        return String(decoding: clean.utf8.prefix(bytes), as: UTF8.self)
    }

    private func connect() async throws {
        if socket != nil { return }
        let binary = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let activePort = profile.appendingPathComponent("DevToolsActivePort")
        // A live dedicated process may survive a host connection or app restart.
        if let endpoint = endpoint(from: activePort), await openSocket(endpoint) { return }
        // A failed DevTools probe does not prove the profile is free to launch.
        if process?.isRunning == true || hasLiveProfileLock() { throw Failure.disconnected }
        try? FileManager.default.removeItem(at: activePort)
        let chrome = Process()
        chrome.executableURL = binary
        chrome.arguments = ["--headless=new", "--user-data-dir=\(profile.path)", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check", "--window-size=1024,768", "about:blank"]
        chrome.standardOutput = FileHandle.nullDevice; chrome.standardError = FileHandle.nullDevice
        guard let authorization, await authorization(), !Task.isCancelled else { throw Failure.protocolError("Pane ownership changed.") }
        try chrome.run()
        process = chrome
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let endpoint = endpoint(from: activePort) {
                guard await openSocket(endpoint) else { throw Failure.disconnected }
                return
            }
            guard chrome.isRunning else { throw Failure.launchFailed }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.launchFailed
    }

    private func hasLiveProfileLock() -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path),
              let raw = destination.split(separator: "-").last, let pid = Int32(raw), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func endpoint(from file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file), data.count < 1024,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let lines = value.split(separator: "\n")
        guard lines.count == 2, let port = UInt16(lines[0]), port > 0,
              lines[1].hasPrefix("/devtools/browser/"), lines[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_/".contains($0)) }) else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)\(lines[1])")
    }

    private func openSocket(_ endpoint: URL) async -> Bool {
        guard let port = endpoint.port else { return false }
        let profile = self.profile
        ChromeDebugPortRegistry.shared.register(port: port, owner: portOwner, isAlive: {
            ChromeDebugPortRegistry.ownsDebugPort(profile: profile, port: port)
        })
        let ws = URLSession.shared.webSocketTask(with: endpoint)
        ws.maximumMessageSize = 2 * 1024 * 1024
        socket = ws
        ws.resume()
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await ws.receive()
                    await self?.received(message)
                } catch { await self?.lostSocket(ws); return }
            }
        }
        do { _ = try await call("Browser.getVersion"); return true }
        catch { lostSocket(ws); return false }
    }

    private func lostSocket(_ ws: URLSessionWebSocketTask) {
        guard socket === ws else { return }
        socket = nil; receiver?.cancel(); receiver = nil
        ws.cancel(with: .goingAway, reason: nil)
        sessionID = nil; selectedTabID = nil; latestFrame = nil
        canGoBack = nil; canGoForward = nil; navigationHistoryDirty = false
        let entries = pending.values; pending.removeAll()
        for entry in entries { entry.timeout.cancel(); entry.send?.cancel(); entry.continuation.resume(throwing: Failure.disconnected) }
    }

    private func call(_ method: String, params: [String: Any] = [:], session: String? = nil, checkAuthorization: Bool = true, offer: (id: UUID, url: String)? = nil) async throws -> [String: Any] {
        if checkAuthorization {
            try Task.checkCancellation()
            guard let authorization, await authorization() else { throw Failure.protocolError("Pane ownership changed.") }
            try Task.checkCancellation()
            if let session, session != sessionID { throw Failure.invalidTab }
        }
        guard let ws = socket else { throw Failure.disconnected }
        guard pending.count < 8 else { throw Failure.busy }
        nextID += 1
        let id = nextID
        var envelope: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { envelope["sessionId"] = session }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let reply: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { await self?.expireCommand(id: id, socket: ws) }
            }
            pending[id] = Pending(continuation: continuation, timeout: timeout, send: nil, offer: offer)
            pending[id]?.send = Task { [weak self] in
                await self?.sendCommand(id: id, data: data, socket: ws, session: session, checkAuthorization: checkAuthorization)
            }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelCommand(id: id, socket: ws) }
        }
        if Task.isCancelled {
            // Closing the browser socket detaches a target even when its attach
            // response arrived after the viewer went away.
            lostSocket(ws)
            throw CancellationError()
        }
        guard let json = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw Failure.disconnected }
        if let error = json["error"] as? [String: Any] { throw Failure.protocolError(String(describing: error["message"] ?? "CDP error")) }
        return json["result"] as? [String: Any] ?? [:]
    }

    private func sendCommand(id: Int, data: Data, socket ws: URLSessionWebSocketTask, session: String?, checkAuthorization: Bool) async {
        var preparedOffer: UUID?
        var sent = false
        do {
            try Task.checkCancellation()
            if checkAuthorization {
                guard let authorization, await authorization() else { throw Failure.protocolError("Pane ownership changed.") }
                if let session, session != sessionID { throw Failure.invalidTab }
            }
            try Task.checkCancellation()
            guard pending[id] != nil, socket === ws else { return }
            if let offer = pending[id]?.offer {
                try offerLaunches.dispatched(offer.id, url: offer.url)
                preparedOffer = offer.id
                // Persisting the receipt can outlive pane ownership or request cancellation.
                guard let authorization, await authorization() else { throw Failure.protocolError("Pane ownership changed.") }
            }
            try Task.checkCancellation()
            guard pending[id] != nil, socket === ws else { throw Failure.disconnected }
            sent = true
            try await ws.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            if let preparedOffer, !sent { try? offerLaunches.abandonUnsent(preparedOffer) }
            fail(id, error: error)
        }
    }

    private func expireCommand(id: Int, socket ws: URLSessionWebSocketTask) {
        guard pending[id] != nil else { return }
        lostSocket(ws)
    }

    private func cancelCommand(id: Int, socket ws: URLSessionWebSocketTask) {
        guard pending[id] != nil else { return }
        // This also releases successful but not-yet-observed CDP attachments.
        lostSocket(ws)
    }

    private func fail(_ id: Int, error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel(); entry.send?.cancel(); entry.continuation.resume(throwing: error)
    }

    private func received(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = json["id"] as? Int, let entry = pending.removeValue(forKey: id) {
            if let offer = entry.offer, let result = json["result"] as? [String: Any], let tabID = result["targetId"] as? String {
                // Save the receipt before resuming a task that may already be cancelled.
                try? offerLaunches.created(offer.id, tabID: tabID)
            }
            entry.timeout.cancel(); entry.send?.cancel(); entry.continuation.resume(returning: data); return
        }
        guard let method = json["method"] as? String,
              let eventSession = json["sessionId"] as? String, eventSession == sessionID else { return }
        if method == "Page.navigatedWithinDocument" {
            navigationHistoryDirty = true
            return
        }
        if method == "Page.frameNavigated" {
            if let frame = (json["params"] as? [String: Any])?["frame"] as? [String: Any], frame["parentId"] == nil {
                navigationHistoryDirty = true
            }
            return
        }
        guard method == "Page.screencastFrame", let tabID = selectedTabID,
              let params = json["params"] as? [String: Any], let ackID = params["sessionId"] as? Int else { return }
        if let metadata = params["metadata"] as? [String: Any],
           metadata["deviceWidth"] as? Double == Double(viewportWidth),
           metadata["deviceHeight"] as? Double == Double(viewportHeight),
           let encoded = params["data"] as? String, encoded.utf8.count <= (Self.maximumCaptureJPEGBytes + 2) / 3 * 4,
           let capture = Data(base64Encoded: encoded), capture.count <= Self.maximumCaptureJPEGBytes,
           let jpeg = Self.boundedViewportJPEG(capture, width: viewportWidth, height: viewportHeight) {
            sequence &+= 1
            latestFrame = .init(tabID: tabID, jpeg: jpeg, sequence: sequence,
                                width: viewportWidth, height: viewportHeight, viewportID: viewportID)
        }
        // ACK after replacing the one-frame cache, including when an oversized frame is dropped.
        nextID += 1
        if let socket, let ack = try? JSONSerialization.data(withJSONObject: ["id": nextID, "method": "Page.screencastFrameAck", "params": ["sessionId": ackID], "sessionId": eventSession]) {
            try? await socket.send(.string(String(decoding: ack, as: UTF8.self)))
        }
    }

    private static func boundedViewportJPEG(_ jpeg: Data, width: Int, height: Int) -> Data? {
        // Chrome can label an old render buffer with new device metrics during resize.
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else { return nil }
        if jpeg.count <= ChromeTabFrame.maximumJPEGBytes { return jpeg }
        // Dimensions are checked before decoding, bounding the bitmap to the allowed viewport.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        for quality in [0.5, 0.35, 0.2] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= ChromeTabFrame.maximumJPEGBytes {
                return output as Data
            }
        }
        return nil
    }
}
#endif
