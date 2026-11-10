import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec AGENT-3.33: When an agent submits a worktree drawing, the application shall accept only a 96-by-64 or 64-unit SVG of at most 16384 bytes built from allowlisted shapes, gradients and text whose paints are palette tokens or local gradient references, and reject scripts, event handlers, external references, embedded images and foreign content.")
struct WorktreeDrawingSVGTests {
    static func svg(_ body: String, viewBox: String = "0 0 64 64") -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(viewBox)\">\(body)</svg>"
    }

    static let sample = svg("""
    <defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="primary-light"/><stop offset="1" stop-color="primary"/></linearGradient></defs>
    <path d="M8 16v32h36V16z" fill="url(#g)" stroke="ink" stroke-width="2.5"/>
    <text x="10" y="40" font-weight="900" font-size="14" fill="white">5k</text>
    """)

    private func rejection(_ svg: String) -> WorktreeDrawingSVG.Rejection? {
        do { _ = try WorktreeDrawingSVG.validate(svg); return nil } catch let error as WorktreeDrawingSVG.Rejection { return error } catch { return .malformed }
    }

    @Test func acceptsTokenDrawing() throws {
        #expect(try WorktreeDrawingSVG.validate("  \(Self.sample)\n") == Self.sample)
    }

    @Test func rejectsScript() {
        #expect(rejection(Self.svg("<script>alert(1)</script>")) == .element("script"))
    }

    @Test func rejectsEventAttribute() {
        #expect(rejection(Self.svg("<rect width=\"4\" height=\"4\" fill=\"ink\" onload=\"x()\"/>")) == .attribute("onload"))
    }

    @Test func rejectsExternalHref() {
        #expect(rejection(Self.svg("<use href=\"http://example.com/a.svg#x\"/>")) == .element("use"))
        #expect(rejection(Self.svg("<rect width=\"4\" height=\"4\" fill=\"ink\" href=\"http://example.com\"/>")) == .attribute("href"))
    }

    @Test func rejectsImage() {
        #expect(rejection(Self.svg("<image href=\"data:image/png;base64,AA==\"/>")) == .element("image"))
    }

    @Test func rejectsForeignObject() {
        #expect(rejection(Self.svg("<foreignObject><div/></foreignObject>")) == .element("foreignObject"))
    }

    @Test func rejectsStyleAttribute() {
        #expect(rejection(Self.svg("<rect width=\"4\" height=\"4\" style=\"fill:url(http://x)\"/>")) == .attribute("style"))
    }

    @Test func rejectsRawColor() {
        #expect(rejection(Self.svg("<rect width=\"4\" height=\"4\" fill=\"#ff0000\"/>")) == .paint("#ff0000"))
    }

    @Test func rejectsUndefinedGradient() {
        #expect(rejection(Self.svg("<rect width=\"4\" height=\"4\" fill=\"url(#missing)\"/>")) == .reference("missing"))
    }

    @Test func rejectsOversize() {
        let padding = String(repeating: " ", count: WorktreeDrawingSVG.maxBytes)
        #expect(rejection(Self.svg("<g>\(padding)</g>")) == .tooLarge)
    }

    @Test func rejectsWrongViewBox() {
        #expect(rejection(Self.svg("<rect width=\"4\" height=\"4\" fill=\"ink\"/>", viewBox: "0 0 24 24")) == .malformed)
    }

    /// Linux's XMLParser recovers from broken markup and still returns true,
    /// reporting the problem only through parseErrorOccurred.
    @Test func rejectsMalformedXML() {
        #expect(rejection("<svg viewBox=\"0 0 64 64\"><rect></svg>") == .malformed)
        #expect(rejection("<svg viewBox=\"0 0 64 64\"><g>") == .malformed)
    }

    @Test func rejectsEntityDeclarations() {
        let bomb = "<!DOCTYPE svg [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\">]>" + Self.svg("<title>&b;</title>")
        #expect(rejection(bomb) == .malformed)
    }

    @Test func rejectionsExplainThemselves() {
        #expect(WorktreeDrawingSVG.Rejection.element("script").description.contains("script"))
        #expect(WorktreeDrawingSVG.Rejection.malformed.description.contains("comments"))
    }
}

@Suite("@spec AGENT-3.39: When an agent submits a worktree drawing, the application shall accept a wide 96-by-64 canvas as well as the older 64-unit square, reject any other canvas, and know which canvas a stored drawing uses.")
struct WorktreeDrawingCanvasTests {
    @Test func acceptsWideAndSquareOnly() throws {
        let wide = WorktreeDrawingSVGTests.svg("<rect width=\"90\" height=\"60\" fill=\"primary\"/>", viewBox: "0 0 96 64")
        #expect(try WorktreeDrawingSVG.validate(wide) == wide)
        #expect(throws: WorktreeDrawingSVG.Rejection.malformed) {
            try WorktreeDrawingSVG.validate(WorktreeDrawingSVGTests.svg("<rect width=\"9\" height=\"9\" fill=\"ink\"/>", viewBox: "0 0 128 64"))
        }
    }

    @Test func readsTheCanvas() {
        #expect(WorktreeDrawing(svg: "<svg viewBox='0 0 96 64'><rect width='9' height='9' fill='ink'/></svg>", hue: 10).canvas == .wide)
        #expect(WorktreeDrawing(svg: WorktreeDrawingSVGTests.sample, hue: 10).canvas == .square)
        #expect(WorktreeDrawingSVG.Canvas.wide.aspect == 1.5)
    }
}
