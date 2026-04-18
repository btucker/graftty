import Testing
import Foundation
@testable import EspalierKit

@Suite("WebStaticResources")
struct WebStaticResourcesTests {

    @Test func loadsIndexHTML() throws {
        let asset = try WebStaticResources.asset(for: "/")
        #expect(asset.data.count > 100)
        #expect(asset.contentType.hasPrefix("text/html"))
    }

    @Test func loadsIndexHTMLExplicitPath() throws {
        let asset = try WebStaticResources.asset(for: "/index.html")
        #expect(asset.data.count > 100)
        #expect(asset.contentType.hasPrefix("text/html"))
    }

    @Test func loadsXtermJS() throws {
        let asset = try WebStaticResources.asset(for: "/xterm.min.js")
        #expect(asset.data.count > 100)
        #expect(asset.contentType == "application/javascript; charset=utf-8")
    }

    @Test func loadsXtermCSS() throws {
        let asset = try WebStaticResources.asset(for: "/xterm.min.css")
        #expect(asset.data.count > 100)
        #expect(asset.contentType == "text/css; charset=utf-8")
    }

    @Test func loadsFitAddon() throws {
        let asset = try WebStaticResources.asset(for: "/xterm-addon-fit.min.js")
        #expect(asset.data.count > 100)
        #expect(asset.contentType == "application/javascript; charset=utf-8")
    }

    @Test func unknownPathThrows() {
        #expect(throws: WebStaticResources.Error.self) {
            _ = try WebStaticResources.asset(for: "/not-a-real-asset.png")
        }
    }
}
