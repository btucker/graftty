#if GRAFTTY_PAGED_HISTORY
import AppKit
import GhosttyKit
import Testing
@testable import Graftty

@MainActor
@Suite("@spec TERM-12.17: When the renderer requests clipboard types only, the application shall report available text types without reading clipboard contents or taking display control.")
struct GhosttyClipboardReadTests {
    @Test func acceptsTypeListingWithoutRequestedMIMEs() {
        #expect(GhosttyClipboardRead.accepts(nil, count: 0, listOnly: true))
        #expect(!GhosttyClipboardRead.accepts(nil, count: 0, listOnly: false))
        for mime in ["text/plain", "image/png"] {
            mime.withCString { pointer in
                let types: [UnsafePointer<CChar>?] = [pointer]
                types.withUnsafeBufferPointer {
                    #expect(GhosttyClipboardRead.accepts($0.baseAddress, count: $0.count, listOnly: true))
                    #expect(GhosttyClipboardRead.accepts($0.baseAddress, count: $0.count, listOnly: false) == (mime == "text/plain"))
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func typeListingReportsOnlyAvailableTypes(hasText: Bool) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        if hasText { pasteboard.setString("private clipboard contents", forType: .string) }
        var reclaimed = false
        GhosttyClipboardRead.complete(listOnly: true, pasteboard: pasteboard, reclaimControl: { reclaimed = true }) {
            let completion = $0.pointee
            #expect(completion.contents == nil)
            #expect(completion.contents_len == 0)
            #expect(completion.available_len == (hasText ? 1 : 0))
            if hasText {
                #expect(completion.available?.pointee.map { String(cString: $0) } == "text/plain")
            }
        }
        #expect(!reclaimed)
    }

    @Test func textPasteReclaimsBeforeCompletingWithExactBytes() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = "A\0B"
        pasteboard.setString(text, forType: .string)
        var reclaimed = false
        GhosttyClipboardRead.complete(listOnly: false, pasteboard: pasteboard, reclaimControl: { reclaimed = true }) {
            #expect(reclaimed)
            #expect($0.pointee.contents_len == 1)
            let content = $0.pointee.contents!.pointee
            #expect(content.len == text.utf8.count)
            #expect(Data(bytes: content.data!, count: content.len) == Data(text.utf8))
        }
    }

    @Test func typeListingDoesNotRequestLazyClipboardData() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let provider = ClipboardReadProbe()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pasteboard.writeObjects([item])
        GhosttyClipboardRead.complete(listOnly: true, pasteboard: pasteboard, reclaimControl: {}) {
            #expect($0.pointee.available_len == 1)
        }
        #expect(provider.reads == 0)
        // Verify the deferred provider is observable when contents are read.
        #expect(pasteboard.string(forType: .string) == "deferred text")
        #expect(provider.reads > 0)
    }
}

private final class ClipboardReadProbe: NSObject, NSPasteboardItemDataProvider {
    var reads = 0
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        item.setString("deferred text", forType: type)
    }
}
#endif
