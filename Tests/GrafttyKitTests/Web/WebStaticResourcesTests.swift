import Testing
import Foundation
@testable import GrafttyKit

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

    @Test func loadsAppJS() throws {
        let asset = try WebStaticResources.asset(for: "/app.js")
        #expect(asset.data.count > 100)
        #expect(asset.contentType == "application/javascript; charset=utf-8")
    }

    @Test func loadsAppCSS() throws {
        let asset = try WebStaticResources.asset(for: "/app.css")
        #expect(asset.data.count > 0)
        #expect(asset.contentType == "text/css; charset=utf-8")
    }

    @Test func unknownPathThrows() {
        #expect(throws: WebStaticResources.Error.self) {
            _ = try WebStaticResources.asset(for: "/does-not-exist.txt")
        }
    }

    @Test func indexHTMLAccessor() throws {
        let asset = try WebStaticResources.indexHTML()
        #expect(asset.contentType.hasPrefix("text/html"))
        #expect(asset.data.count > 100)
    }
}
