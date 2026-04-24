import Foundation

public enum AppcastUpdater {

    public enum Error: Swift.Error {
        case malformedXML(String)
    }

    /// Prepend a new `<item>` for `item` to the given feed XML, or seed a
    /// fresh feed if `existingXML` is nil / empty. Idempotent on version —
    /// if an item with `<sparkle:version>item.version</sparkle:version>`
    /// already exists, the input is returned unchanged.
    public static func prepend(item: AppcastItem, to existingXML: String?) throws -> String {
        let doc = try document(from: existingXML)
        guard let channel = try channelElement(in: doc) else {
            throw Error.malformedXML("no <channel> element")
        }
        if channelContainsVersion(channel, version: item.version) {
            return try format(doc)
        }
        let newItem = makeItemElement(item)
        // Insert as the first child of <channel> that is an <item> — i.e.
        // before any existing items, but after the channel's metadata
        // elements (title / link / description / language). Sparkle
        // ignores item order (it picks by version), but humans reading
        // the file expect newest-first.
        let firstItemIndex = channel.children?.firstIndex { ($0 as? XMLElement)?.name == "item" }
            ?? channel.children?.count
            ?? 0
        channel.insertChild(newItem, at: firstItemIndex)
        return try format(doc)
    }

    private static func document(from existingXML: String?) throws -> XMLDocument {
        if let xml = existingXML?.trimmingCharacters(in: .whitespacesAndNewlines), !xml.isEmpty {
            return try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        }
        return seedDocument()
    }

    private static func seedDocument() -> XMLDocument {
        let doc = XMLDocument(rootElement: nil)
        doc.version = "1.0"
        doc.characterEncoding = "utf-8"
        let rss = XMLElement(name: "rss")
        rss.addAttribute(XMLNode.attribute(withName: "version", stringValue: "2.0") as! XMLNode)
        rss.addAttribute(XMLNode.attribute(
            withName: "xmlns:sparkle",
            stringValue: "http://www.andymatuschak.org/xml-namespaces/sparkle"
        ) as! XMLNode)
        let channel = XMLElement(name: "channel")
        channel.addChild(XMLElement(name: "title", stringValue: "Graftty"))
        channel.addChild(XMLElement(name: "link", stringValue: "https://github.com/btucker/graftty"))
        channel.addChild(XMLElement(name: "description", stringValue: "Updates for Graftty."))
        channel.addChild(XMLElement(name: "language", stringValue: "en"))
        rss.addChild(channel)
        doc.setRootElement(rss)
        return doc
    }

    private static func channelElement(in doc: XMLDocument) throws -> XMLElement? {
        guard let root = doc.rootElement(), root.name == "rss" else {
            throw Error.malformedXML("root is not <rss>")
        }
        return root.elements(forName: "channel").first
    }

    private static func channelContainsVersion(_ channel: XMLElement, version: String) -> Bool {
        for item in channel.elements(forName: "item") {
            if let v = item.elements(forName: "sparkle:version").first?.stringValue,
               v == version {
                return true
            }
        }
        return false
    }

    private static func makeItemElement(_ item: AppcastItem) -> XMLElement {
        let el = XMLElement(name: "item")
        el.addChild(XMLElement(name: "title", stringValue: "Version \(item.version)"))
        el.addChild(XMLElement(name: "sparkle:version", stringValue: item.version))
        el.addChild(XMLElement(name: "sparkle:shortVersionString", stringValue: item.version))
        el.addChild(XMLElement(name: "pubDate", stringValue: rfc822(item.pubDate)))
        el.addChild(XMLElement(
            name: "sparkle:minimumSystemVersion",
            stringValue: item.minimumSystemVersion
        ))

        // Release-notes go in a CDATA section so markdown backticks, ampersands
        // and angle brackets pass through verbatim. XMLElement's stringValue
        // setter would entity-escape them, which Sparkle's WebView then
        // double-decodes incorrectly. Build the CDATA node manually.
        let description = XMLElement(name: "description")
        let cdata = XMLNode(kind: .text, options: [.nodeIsCDATA])
        cdata.stringValue = item.releaseNotesMarkdown
        description.addChild(cdata)
        el.addChild(description)

        let enclosure = XMLElement(name: "enclosure")
        enclosure.addAttribute(XMLNode.attribute(withName: "url", stringValue: item.downloadURL) as! XMLNode)
        enclosure.addAttribute(XMLNode.attribute(withName: "length", stringValue: String(item.contentLength)) as! XMLNode)
        enclosure.addAttribute(XMLNode.attribute(withName: "type", stringValue: "application/octet-stream") as! XMLNode)
        enclosure.addAttribute(XMLNode.attribute(
            withName: "sparkle:edSignature",
            stringValue: item.edSignature
        ) as! XMLNode)
        el.addChild(enclosure)
        return el
    }

    private static func rfc822(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return fmt.string(from: date)
    }

    private static func format(_ doc: XMLDocument) throws -> String {
        let data = doc.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.malformedXML("cannot re-encode document")
        }
        return s
    }
}
