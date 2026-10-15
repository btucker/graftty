#if os(macOS)
import Foundation
import GrafttyProtocol
import ImageIO
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import GrafttyKit

private final class ChromeNavigationPage: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        let body = context.channel.allocator.buffer(string: """
        <!doctype html><title>Navigation fixture</title><p>Host browser history</p>
        <style>body{margin:0}button{position:fixed;left:75%;top:75%;transform:translate(-50%,-50%);width:60px;height:60px}</style>
        <button id="hit" onclick="window.hits=(window.hits||0)+1">Tap</button>
        """)
        let headers = HTTPHeaders([("Content-Type", "text/html"), ("Content-Length", String(body.readableBytes))])
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private actor NavigationPermission {
    private var checks = 0
    let maximumChecks: Int
    init(maximumChecks: Int) { self.maximumChecks = maximumChecks }
    func permits() -> Bool { checks += 1; return checks <= maximumChecks }
    func count() -> Int { checks }
}

@Suite(.serialized)
struct DedicatedChromeNavigationTests {
    @Test("@spec CHROME-1.17: When a high-entropy page produces an oversized JPEG at an allowed host viewport, the application shall provide a frame within 512 KiB without changing its CSS dimensions and allow input after that fresh frame.", .timeLimit(.minutes(1)))
    func compressesHighEntropyFrameAtMaximumViewport() async throws {
        try await withPage { backend, port in
            let launched = try await backend.perform(.launch(url: "http://127.0.0.1:\(port)/noise"), authorize: { true })
            let tab = try #require(launched.selectedTabID)
            let resized = try await backend.perform(.viewport(tabID: tab, width: 1024, height: 1464), authorize: { true })
            let before = try await waitForFrame(tab, width: 1024, height: 1464, viewportID: resized.viewportID, backend: backend)
            let originalBytes = try await backend.evaluateForTesting("""
            (() => {
              const canvas = document.createElement('canvas');
              canvas.width = innerWidth; canvas.height = innerHeight;
              canvas.style.display = 'block'; document.body.style.overflow = 'hidden';
              document.body.replaceChildren(canvas);
              const ctx = canvas.getContext('2d'), pixels = ctx.createImageData(canvas.width, canvas.height);
              let seed = 123456789;
              for (let i = 0; i < pixels.data.length; i += 4) {
                seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
                pixels.data[i] = seed & 255; pixels.data[i+1] = (seed >>> 8) & 255;
                pixels.data[i+2] = (seed >>> 16) & 255; pixels.data[i+3] = 255;
              }
              ctx.putImageData(pixels, 0, 0);
              canvas.onclick = () => window.noiseHits = (window.noiseHits || 0) + 1;
              return atob(canvas.toDataURL('image/jpeg', 0.65).split(',')[1]).length;
            })()
            """)
            #expect(Int(originalBytes) ?? 0 > ChromeTabFrame.maximumJPEGBytes)
            print("High-entropy canvas source JPEG bytes:", originalBytes)
            var frame = before
            for _ in 0..<60 {
                frame = try #require(try await backend.perform(.frame(tabID: tab), authorize: { true }).frame)
                if frame.sequence > before.sequence { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(frame.sequence > before.sequence)
            #expect(frame.jpeg != before.jpeg)
            #expect(frame.jpeg.count <= ChromeTabFrame.maximumJPEGBytes)
            #expect(frame.width == 1024 && frame.height == 1464)
            let source = try #require(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1464)
            print("High-entropy viewer JPEG bytes:", frame.jpeg.count)
            _ = try await backend.perform(.tap(tabID: tab, x: 0.75, y: 0.75), authorize: { true })
            #expect(try await backend.evaluateForTesting("window.noiseHits") == "1")
        }
    }

    @Test("@spec CHROME-1.12: When an authorized viewer resizes its selected host tab, the application shall restart capture with bounded CSS dimensions and a new viewport identity, retain those dimensions on each JPEG, and dispatch normalized input in the new viewport.", .timeLimit(.minutes(1)))
    func resizesPortraitAndLandscapeAndTapsDOMPoint() async throws {
        try await withPage { backend, port in
            let launched = try await backend.perform(.launch(url: "http://127.0.0.1:\(port)/viewport"), authorize: { true })
            let tab = try #require(launched.selectedTabID)
            var previous = try await waitForFrame(tab, width: 1024, height: 768, viewportID: launched.viewportID, backend: backend)
            for (width, height) in [(375, 812), (1024, 768)] {
                let resized = try await backend.perform(.viewport(tabID: tab, width: width, height: height), authorize: { true })
                let viewportID = try #require(resized.viewportID)
                #expect(viewportID != previous.viewportID)
                #expect(resized.width == width)
                #expect(resized.height == height)
                if let frame = resized.frame {
                    #expect(frame.viewportID == viewportID)
                    #expect(frame.width == width && frame.height == height)
                    #expect(frame.sequence > previous.sequence)
                }
                let frame = try await waitForFrame(tab, width: width, height: height, viewportID: viewportID, backend: backend)
                let source = try #require(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
                #expect(properties[kCGImagePropertyPixelHeight] as? Int == height)
                #expect(frame.jpeg.count <= ChromeTabFrame.maximumJPEGBytes)
                #expect(try await backend.evaluateForTesting("innerWidth + 'x' + innerHeight") == "\(width)x\(height)")
                _ = try await backend.perform(.tap(tabID: tab, x: 0.75, y: 0.75), authorize: { true })
                previous = frame
            }
            #expect(try await backend.evaluateForTesting("window.hits") == "2")
        }
    }

    @Test("@spec CHROME-1.15: When a selected host tab exposes a navigable URL of at most 8192 UTF8 bytes, the application shall preserve that exact URL in tab metadata and flag longer URLs as truncated without exceeding the Chrome response limit.", .timeLimit(.minutes(1)))
    func preservesExactLongURLAndFlagsTruncation() async throws {
        try await withPage { backend, port in
            let base = "http://127.0.0.1:\(port)/url?state=A%2Bb&value="
            let launched = try await backend.perform(.launch(url: base), authorize: { true })
            let tab = try #require(launched.selectedTabID)
            for length in [8192, 8193] {
                let original = base + String(repeating: "x", count: length - base.utf8.count)
                let literal = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
                _ = try await backend.evaluateForTesting("history.replaceState(null, '', \(literal)); location.href")
                let state = try await backend.perform(.frame(tabID: tab), authorize: { true })
                let metadata = try #require(state.tabs.first(where: { $0.id == tab }))
                #expect(metadata.url == String(original.prefix(8192)))
                #expect(metadata.urlTruncated == (length > 8192))
                #expect(try ChromeTabResponse(state: state).encoded().count <= ChromeTabRequest.maximumResponseBytes)
                if length == 8192 {
                    let other = try await backend.perform(.launch(url: "http://127.0.0.1:\(port)/other"), authorize: { true })
                    let shortened = try #require(other.tabs.first(where: { $0.id == tab }))
                    #expect(shortened.url.utf8.count == 2048)
                    #expect(shortened.urlTruncated == true)
                    let selected = try await backend.perform(.select(tabID: tab), authorize: { true })
                    let exact = try #require(selected.tabs.first(where: { $0.id == tab }))
                    #expect(exact.url == original && exact.urlTruncated == false)
                }
            }
        }
    }

    @Test("@spec CHROME-1.10: When an authorized viewer requests back, forward, or reload for its selected host tab, the application shall navigate that tab's existing history or reload its document and report available history without creating another tab.", .timeLimit(.minutes(1)))
    func navigatesSelectedTabHistoryAndReloadsDocument() async throws {
        try await withPage { backend, port in
            let launched = try await backend.perform(.launch(url: "http://127.0.0.1:\(port)/first"), authorize: { true })
            let tab = try #require(launched.selectedTabID)
            _ = try await backend.evaluateForTesting("window.navigationMarker = 41; history.pushState({}, '', '/second'); location.pathname")
            let second = try await backend.perform(.frame(tabID: tab), authorize: { true })
            #expect(second.canGoBack == true)
            #expect(second.canGoForward == false)

            _ = try await backend.perform(.back(tabID: tab), authorize: { true })
            try await expectValue("location.pathname", equals: "/first", backend: backend)
            let first = try await backend.perform(.frame(tabID: tab), authorize: { true })
            #expect(first.canGoBack == false)
            #expect(first.canGoForward == true)
            _ = try await backend.perform(.back(tabID: tab), authorize: { true })
            #expect(try await backend.evaluateForTesting("location.pathname") == "/first")

            _ = try await backend.perform(.forward(tabID: tab), authorize: { true })
            try await expectValue("location.pathname", equals: "/second", backend: backend)
            #expect(try await backend.evaluateForTesting("window.navigationMarker") == "41")
            _ = try await backend.perform(.reload(tabID: tab), authorize: { true })
            try await expectValue("typeof window.navigationMarker", equals: "undefined", backend: backend)
            let reloaded = try await backend.perform(.frame(tabID: tab), authorize: { true })
            #expect(reloaded.selectedTabID == tab)
            #expect(reloaded.tabs.count == launched.tabs.count)
            #expect(reloaded.canGoBack == true)
            #expect(reloaded.canGoForward == false)
        }
    }

    @Test("@spec CHROME-1.11: If a navigation command names a nonselected host tab or pane ownership changes before dispatch, then the application shall reject back, forward, and reload before changing the selected tab's document or history.", .timeLimit(.minutes(1)))
    func rejectsNonselectedTabsAndRechecksNavigationOwnership() async throws {
        try await withPage { backend, port in
            let first = try await backend.perform(.launch(url: "http://127.0.0.1:\(port)/first"), authorize: { true })
            let tab = try #require(first.selectedTabID)
            _ = try await backend.evaluateForTesting("history.pushState({}, '', '/second'); location.pathname")
            _ = try await backend.perform(.launch(url: "http://127.0.0.1:\(port)/other"), authorize: { true })
            for action in [ChromeTabAction.back(tabID: tab), .forward(tabID: tab), .reload(tabID: tab)] {
                await #expect(throws: (any Error).self) {
                    try await backend.perform(action, authorize: { true })
                }
            }
            #expect(try await backend.evaluateForTesting("location.pathname") == "/other")
            _ = try await backend.perform(.select(tabID: tab), authorize: { true })

            let backPermission = NavigationPermission(maximumChecks: 5)
            await #expect(throws: (any Error).self) {
                try await backend.perform(.back(tabID: tab), authorize: { await backPermission.permits() })
            }
            #expect(await backPermission.count() == 6)
            #expect(try await backend.evaluateForTesting("location.pathname") == "/second")
            _ = try await backend.perform(.back(tabID: tab), authorize: { true })
            try await expectValue("location.pathname", equals: "/first", backend: backend)

            let forwardPermission = NavigationPermission(maximumChecks: 5)
            await #expect(throws: (any Error).self) {
                try await backend.perform(.forward(tabID: tab), authorize: { await forwardPermission.permits() })
            }
            #expect(await forwardPermission.count() == 6)
            #expect(try await backend.evaluateForTesting("location.pathname") == "/first")
            _ = try await backend.evaluateForTesting("window.navigationMarker = 71")
            let reloadPermission = NavigationPermission(maximumChecks: 3)
            await #expect(throws: (any Error).self) {
                try await backend.perform(.reload(tabID: tab), authorize: { await reloadPermission.permits() })
            }
            #expect(await reloadPermission.count() == 4)
            #expect(try await backend.evaluateForTesting("window.navigationMarker") == "71")
        }
    }
}

private func waitForFrame(_ tab: String, width: Int, height: Int, viewportID: UInt64?, backend: DedicatedChromeBackend) async throws -> ChromeTabFrame {
    var latest: ChromeTabFrame?
    for _ in 0..<60 {
        latest = try await backend.perform(.frame(tabID: tab), authorize: { true }).frame
        if let latest, latest.width == width, latest.height == height, latest.viewportID == viewportID { return latest }
        try await Task.sleep(for: .milliseconds(50))
    }
    let frame = try #require(latest)
    #expect(frame.width == width && frame.height == height)
    #expect(frame.viewportID == viewportID)
    return frame
}

private func expectValue(_ expression: String, equals expected: String, backend: DedicatedChromeBackend) async throws {
    for _ in 0..<40 {
        if (try? await backend.evaluateForTesting(expression)) == expected { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try await backend.evaluateForTesting(expression) == expected)
}

private func withPage(_ body: @Sendable (DedicatedChromeBackend, Int) async throws -> Void) async throws {
    let root = URL.temporaryDirectory.appendingPathComponent("graftty-native-navigation-\(UUID())")
    let backend = DedicatedChromeBackend(testProfile: root.appendingPathComponent(String(repeating: "d", count: 64)))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(ChromeNavigationPage()) }
    }.bind(host: "127.0.0.1", port: 0).get()
    do {
        try await body(backend, try #require(server.localAddress?.port))
    } catch {
        await backend.shutdownForTesting()
        try? await server.close().get(); try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: root)
        throw error
    }
    await backend.shutdownForTesting()
    try await server.close().get(); try await group.shutdownGracefully()
    try FileManager.default.removeItem(at: root)
}
#endif
