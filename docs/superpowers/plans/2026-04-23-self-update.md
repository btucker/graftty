# Self-Update via Sparkle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an in-app self-update mechanism for Graftty using Sparkle 2. The app checks the appcast daily, surfaces new versions with a non-modal badge in the window titlebar (right of the traffic lights), and installs the update via Sparkle's standard dialog. The release workflow signs each release zip with EdDSA and commits a new entry to `appcast.xml` on `main`.

**Architecture:** New `Sources/GrafttyKit/Updater/` module wraps `SPUStandardUpdaterController` behind a small Swift-facing API. The controller conforms to `SPUStandardUserDriverDelegate` and vetoes Sparkle's modal on silent scheduled checks (publishing the pending update into a titlebar-badge view-model); user-initiated checks — menu or badge click — re-trigger `updater.checkForUpdates(nil)` and let the standard driver present its dialog. A new SwiftPM library target `AppcastUpdater` + executable `appcast-updater` handle the CI-side XML writing. Release workflow gains three steps: build `sign_update`, sign the zip, commit an appcast entry. The Homebrew cask gains `auto_updates true` so `brew upgrade` stops competing with Sparkle.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSTitlebarAccessoryViewController`), **new dep: Sparkle 2 (`https://github.com/sparkle-project/Sparkle`)**, `Foundation.XMLDocument` for appcast authoring, swift-testing (`@Suite`/`@Test`).

**Spec source:** `docs/superpowers/specs/2026-04-23-self-update-design.md` (commit `41648ed`).

---

## File Structure

### Modified
- `Package.swift` — add Sparkle dependency, new `AppcastUpdater` library target, new `appcast-updater` executable target, new `AppcastUpdaterTests` test target, add `Sparkle` product to `GrafttyKit` and `Graftty` targets.
- `scripts/bundle.sh` — Info.plist heredoc gains `SUFeedURL` and `SUPublicEDKey`; helpers/codesign block unchanged (Sparkle's frameworks ship inside the SwiftPM-built app binary and don't need separate signing).
- `.github/workflows/release.yml` — after `Zip artifact`: build `sign_update`, sign the zip, run `appcast-updater` + commit to `main`.
- `docs/release/README.md` — new "One-time setup for Sparkle" section; update "Keeping the cask in sync" to mention `auto_updates true`.
- `docs/release/Casks/graftty.rb` — add `auto_updates true` stanza.
- `Sources/Graftty/GrafttyApp.swift` — construct `UpdaterController` in `AppServices`, install the titlebar accessory after the window is ready, add "Check for Updates…" and "Automatically Check for Updates" menu items.
- `Sources/Graftty/Views/MainWindow.swift` — attach a `WindowAccessoryInstaller` helper view that installs the titlebar accessory on the host `NSWindow` (same `NSViewRepresentable` + `viewDidMoveToWindow` pattern as `WindowBackgroundTint`).
- `SPECS.md` — new `UPDATE-*` section before the Keyboard Shortcuts section.
- `README.md` — one-line mention of self-updates under "Installing" (brew still recommended for first install; after that the app updates itself).

### Created
- `Sources/AppcastUpdater/AppcastUpdater.swift` — `XMLDocument`-based library: read existing feed, seed empty shell on first run, prepend a new `<item>`, preserve existing items, be idempotent on same version.
- `Sources/AppcastUpdater/AppcastItem.swift` — plain struct for a single release entry (version, pubDate, minSystem, description, url, length, edSignature).
- `Sources/appcast-updater/main.swift` — CLI wrapper: parses args, reads/writes files, calls `AppcastUpdater`.
- `Tests/AppcastUpdaterTests/AppcastUpdaterTests.swift` — `@Suite` covering seed-on-empty, prepend-new-entry, preserve-existing, idempotent-same-version, release-notes-CDATA-escape.
- `Tests/AppcastUpdaterTests/Fixtures/empty-feed.xml` — `<rss>` shell with no items.
- `Tests/AppcastUpdaterTests/Fixtures/one-item-feed.xml` — feed with a single prior release, used to test prepending.
- `Sources/GrafttyKit/Updater/UpdaterController.swift` — `ObservableObject` wrapping `SPUStandardUpdaterController`. Exposes `@Published` state: `updateAvailable: Bool`, `availableVersion: String?`, `canCheckForUpdates: Bool`. Methods: `checkForUpdatesWithUI()`, `showPendingUpdate()`.
- `Sources/GrafttyKit/Updater/UpdaterController+Delegate.swift` — `UpdaterController` extension conforming to `SPUStandardUserDriverDelegate`. Returns `false` from `standardUserDriverShouldHandleShowingScheduledUpdate(…, andInImmediateFocus:)` to suppress Sparkle's modal on scheduled checks, publishes the pending update's version into controller state, and on badge click re-kicks `updater.checkForUpdates(nil)` which surfaces the stored update via the standard driver (this time with user-initiated immediate focus, so the modal does show).
- `Sources/GrafttyKit/Updater/UpdaterTitlebarAccessory.swift` — `NSTitlebarAccessoryViewController` subclass hosting a SwiftUI `UpdateBadge` view; exposes `install(on:)` to attach itself at `layoutAttribute = .leading`.
- `Sources/GrafttyKit/Updater/UpdateBadge.swift` — SwiftUI view that observes `UpdaterController` and renders the pill button (hidden when `!updateAvailable`).
- `Sources/Graftty/Views/WindowAccessoryInstaller.swift` — `NSViewRepresentable` that installs the titlebar accessory once the host `NSWindow` is available; accepts a controller and constructs the accessory on `viewDidMoveToWindow`.
- `Tests/GrafttyKitTests/Updater/UpdaterControllerStateTests.swift` — state-transition tests driven by calling the controller's public "driver hooks" directly (no real Sparkle wired).
- `appcast.xml` — seed file at repo root on `main` (empty `<rss>` shell). Sparkle polls `https://raw.githubusercontent.com/btucker/graftty/main/appcast.xml`.

---

## Task 1: Add Sparkle dependency and new SwiftPM targets

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the Sparkle package dependency**

Edit `Package.swift`. In the `dependencies: [...]` array, append after the existing swift-nio-ssl entry:

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
```

- [ ] **Step 2: Add Sparkle to GrafttyKit and Graftty target dependencies**

In the `GrafttyKit` target's `dependencies: [...]`, append:

```swift
.product(name: "Sparkle", package: "Sparkle"),
```

In the `Graftty` executable target's `dependencies: [...]`, append the same line (so the app target can reach AppKit-side Sparkle types directly when wiring the user driver, without re-exporting them through GrafttyKit's public API).

- [ ] **Step 3: Add the AppcastUpdater library target**

In the `targets: [...]` array, add a new entry before the existing `.target(name: "GrafttyKit", …)`:

```swift
.target(
    name: "AppcastUpdater",
    swiftSettings: strictWarnings
),
```

- [ ] **Step 4: Add the appcast-updater executable target**

In `targets: [...]`, add after the `GrafttyCLI` executable target:

```swift
.executableTarget(
    name: "appcast-updater",
    dependencies: ["AppcastUpdater"],
    swiftSettings: strictWarnings
),
```

- [ ] **Step 5: Add the AppcastUpdaterTests test target**

In `targets: [...]`, add after the existing `GrafttyProtocolTests` test target:

```swift
.testTarget(
    name: "AppcastUpdaterTests",
    dependencies: ["AppcastUpdater"],
    resources: [
        .copy("Fixtures"),
    ],
    swiftSettings: strictWarnings
),
```

- [ ] **Step 6: Expose the new executable product**

In the `products: [...]` array, append after the existing `graftty-cli` executable product:

```swift
.executable(name: "appcast-updater", targets: ["appcast-updater"]),
```

- [ ] **Step 7: Resolve and build**

Run: `swift package resolve`
Expected: exits 0, `Package.resolved` gains a `Sparkle` pin. (Sparkle brings in no transitive SwiftPM deps at runtime.)

Run: `swift build`
Expected: exits 0, no new warnings. Sparkle's framework links cleanly against macOS 14.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "deps: add Sparkle + AppcastUpdater targets (UPDATE-*)"
```

---

## Task 2: AppcastItem data struct

**Files:**
- Create: `Sources/AppcastUpdater/AppcastItem.swift`

- [ ] **Step 1: Write the data type**

Create `Sources/AppcastUpdater/AppcastItem.swift`:

```swift
import Foundation

/// One release entry for the Sparkle appcast feed.
///
/// `version` is the canonical short version string (e.g. "0.2.3"). We do
/// not distinguish `sparkle:version` from `sparkle:shortVersionString` —
/// Graftty ships a single versioning series, and the appcast writer emits
/// both elements with the same value.
public struct AppcastItem: Equatable, Sendable {
    public let version: String
    public let pubDate: Date
    public let minimumSystemVersion: String
    public let releaseNotesMarkdown: String
    public let downloadURL: String
    public let contentLength: Int
    public let edSignature: String

    public init(
        version: String,
        pubDate: Date,
        minimumSystemVersion: String,
        releaseNotesMarkdown: String,
        downloadURL: String,
        contentLength: Int,
        edSignature: String
    ) {
        self.version = version
        self.pubDate = pubDate
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotesMarkdown = releaseNotesMarkdown
        self.downloadURL = downloadURL
        self.contentLength = contentLength
        self.edSignature = edSignature
    }
}
```

- [ ] **Step 2: Build to confirm**

Run: `swift build --target AppcastUpdater`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppcastUpdater/AppcastItem.swift
git commit -m "feat(appcast): AppcastItem data struct (UPDATE-2.1)"
```

---

## Task 3: AppcastUpdater core — seed + prepend + idempotency (TDD)

**Files:**
- Create: `Sources/AppcastUpdater/AppcastUpdater.swift`
- Create: `Tests/AppcastUpdaterTests/AppcastUpdaterTests.swift`
- Create: `Tests/AppcastUpdaterTests/Fixtures/empty-feed.xml`
- Create: `Tests/AppcastUpdaterTests/Fixtures/one-item-feed.xml`

- [ ] **Step 1: Write the fixtures**

Create `Tests/AppcastUpdaterTests/Fixtures/empty-feed.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Graftty</title>
        <link>https://github.com/btucker/graftty</link>
        <description>Updates for Graftty.</description>
        <language>en</language>
    </channel>
</rss>
```

Create `Tests/AppcastUpdaterTests/Fixtures/one-item-feed.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Graftty</title>
        <link>https://github.com/btucker/graftty</link>
        <description>Updates for Graftty.</description>
        <language>en</language>
        <item>
            <title>Version 0.1.0</title>
            <sparkle:version>0.1.0</sparkle:version>
            <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
            <pubDate>Mon, 01 Apr 2026 12:00:00 +0000</pubDate>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[First release]]></description>
            <enclosure url="https://github.com/btucker/graftty/releases/download/v0.1.0/Graftty-0.1.0.zip" length="1000000" type="application/octet-stream" sparkle:edSignature="sig01" />
        </item>
    </channel>
</rss>
```

- [ ] **Step 2: Write the failing test suite**

Create `Tests/AppcastUpdaterTests/AppcastUpdaterTests.swift`:

```swift
import Testing
import Foundation
@testable import AppcastUpdater

@Suite("AppcastUpdater")
struct AppcastUpdaterTests {

    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "xml",
                                    subdirectory: "Fixtures")!
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_713_830_400)
    // 2024-04-23 00:00:00 UTC — stable RFC822 for golden-file comparison.

    private func newItem(version: String, notes: String = "notes", signature: String = "sig")
    -> AppcastItem {
        AppcastItem(
            version: version,
            pubDate: fixedDate,
            minimumSystemVersion: "14.0",
            releaseNotesMarkdown: notes,
            downloadURL: "https://github.com/btucker/graftty/releases/download/v\(version)/Graftty-\(version).zip",
            contentLength: 1234,
            edSignature: signature
        )
    }

    @Test func seedsEmptyFeedWhenInputIsNil() throws {
        let out = try AppcastUpdater.prepend(item: newItem(version: "0.2.0"), to: nil)
        #expect(out.contains("<rss"))
        #expect(out.contains("<sparkle:version>0.2.0</sparkle:version>"))
        #expect(out.contains("<channel>"))
    }

    @Test func prependsToExistingFeed() throws {
        let existing = try fixture("one-item-feed")
        let out = try AppcastUpdater.prepend(item: newItem(version: "0.2.0"), to: existing)
        // New entry comes first.
        let idxNew = out.range(of: "<sparkle:version>0.2.0</sparkle:version>")!.lowerBound
        let idxOld = out.range(of: "<sparkle:version>0.1.0</sparkle:version>")!.lowerBound
        #expect(idxNew < idxOld)
        // Old entry preserved intact.
        #expect(out.contains("sig01"))
        #expect(out.contains("Graftty-0.1.0.zip"))
    }

    @Test func isIdempotentOnSameVersion() throws {
        let existing = try fixture("one-item-feed")
        let out = try AppcastUpdater.prepend(item: newItem(version: "0.1.0"), to: existing)
        // Exactly one `<sparkle:version>0.1.0</sparkle:version>` after the no-op.
        let occurrences = out.components(separatedBy: "<sparkle:version>0.1.0</sparkle:version>").count - 1
        #expect(occurrences == 1)
    }

    @Test func escapesReleaseNotesWithCDATA() throws {
        let notes = "Fix: handle `<tag>` & quote\"breaks"
        let out = try AppcastUpdater.prepend(
            item: newItem(version: "0.3.0", notes: notes),
            to: nil
        )
        // CDATA section must be present with the raw content — no entity encoding.
        #expect(out.contains("<![CDATA[\(notes)]]>"))
    }

    @Test func enclosureCarriesLengthAndSignature() throws {
        let out = try AppcastUpdater.prepend(
            item: newItem(version: "0.4.0", signature: "abc123=="),
            to: nil
        )
        #expect(out.contains("length=\"1234\""))
        #expect(out.contains("sparkle:edSignature=\"abc123==\""))
        #expect(out.contains("type=\"application/octet-stream\""))
    }

    @Test func minimumSystemVersionFromItem() throws {
        let item = AppcastItem(
            version: "0.5.0",
            pubDate: fixedDate,
            minimumSystemVersion: "15.0",
            releaseNotesMarkdown: "",
            downloadURL: "https://example.com/x.zip",
            contentLength: 1,
            edSignature: "s"
        )
        let out = try AppcastUpdater.prepend(item: item, to: nil)
        #expect(out.contains("<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>"))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter AppcastUpdaterTests`
Expected: FAIL — `AppcastUpdater` type not found.

- [ ] **Step 4: Implement `AppcastUpdater.prepend`**

Create `Sources/AppcastUpdater/AppcastUpdater.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter AppcastUpdaterTests`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppcastUpdater/AppcastUpdater.swift \
        Tests/AppcastUpdaterTests/AppcastUpdaterTests.swift \
        Tests/AppcastUpdaterTests/Fixtures/empty-feed.xml \
        Tests/AppcastUpdaterTests/Fixtures/one-item-feed.xml
git commit -m "feat(appcast): XMLDocument-based feed writer with idempotency (UPDATE-2.1)"
```

---

## Task 4: appcast-updater executable

**Files:**
- Create: `Sources/appcast-updater/main.swift`

- [ ] **Step 1: Write the CLI driver**

Create `Sources/appcast-updater/main.swift`:

```swift
import Foundation
import AppcastUpdater

// Minimal argv parser — avoids pulling swift-argument-parser into this
// narrowly-scoped CI tool. Usage:
//
//   appcast-updater \
//     --feed <path/to/appcast.xml> \
//     --version <X.Y.Z> \
//     --download-url <URL> \
//     --length <BYTES> \
//     --ed-signature <BASE64> \
//     --minimum-system-version 14.0 \
//     --release-notes <path/to/notes.md>  # or '-' for stdin
//
// Writes the updated feed back to --feed in place. Seeds an empty feed
// if --feed does not exist. Exits non-zero on parse or write failure.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("appcast-updater: \(msg)\n".utf8))
    exit(2)
}

struct Args {
    var feed: String?
    var version: String?
    var downloadURL: String?
    var length: Int?
    var edSignature: String?
    var minimumSystemVersion: String = "14.0"
    var releaseNotesPath: String?
}

func parse(_ argv: [String]) -> Args {
    var a = Args()
    var i = 1
    while i < argv.count {
        let k = argv[i]
        guard i + 1 < argv.count else { fail("missing value for \(k)") }
        let v = argv[i + 1]
        switch k {
        case "--feed": a.feed = v
        case "--version": a.version = v
        case "--download-url": a.downloadURL = v
        case "--length":
            guard let n = Int(v) else { fail("--length must be an integer") }
            a.length = n
        case "--ed-signature": a.edSignature = v
        case "--minimum-system-version": a.minimumSystemVersion = v
        case "--release-notes": a.releaseNotesPath = v
        default: fail("unknown flag: \(k)")
        }
        i += 2
    }
    return a
}

func readReleaseNotes(_ path: String?) -> String {
    guard let path else { return "" }
    if path == "-" {
        return String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

let args = parse(CommandLine.arguments)
guard let feed = args.feed,
      let version = args.version,
      let url = args.downloadURL,
      let length = args.length,
      let signature = args.edSignature else {
    fail("required: --feed --version --download-url --length --ed-signature")
}

let existing = try? String(contentsOfFile: feed, encoding: .utf8)
let item = AppcastItem(
    version: version,
    pubDate: Date(),
    minimumSystemVersion: args.minimumSystemVersion,
    releaseNotesMarkdown: readReleaseNotes(args.releaseNotesPath),
    downloadURL: url,
    contentLength: length,
    edSignature: signature
)

do {
    let out = try AppcastUpdater.prepend(item: item, to: existing)
    try out.write(toFile: feed, atomically: true, encoding: .utf8)
} catch {
    fail("\(error)")
}
```

- [ ] **Step 2: Build and smoke-test**

Run: `swift build --product appcast-updater`
Expected: exits 0.

Smoke-test (does not get committed, just verifies the binary runs end-to-end):

```bash
TMP=$(mktemp -d)
swift run appcast-updater \
  --feed "$TMP/appcast.xml" \
  --version 0.1.0 \
  --download-url "https://example.com/Graftty-0.1.0.zip" \
  --length 123456 \
  --ed-signature "fakesig==" \
  --release-notes /dev/null
cat "$TMP/appcast.xml"
rm -rf "$TMP"
```

Expected output: a well-formed `<rss>` document containing the single item.

- [ ] **Step 3: Commit**

```bash
git add Sources/appcast-updater/main.swift
git commit -m "feat(appcast): appcast-updater CLI for release workflow (UPDATE-2.1)"
```

---

## Task 5: Seed the appcast feed on main

**Files:**
- Create: `appcast.xml`

- [ ] **Step 1: Write the seed feed**

Create `appcast.xml` at the repo root:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Graftty</title>
        <link>https://github.com/btucker/graftty</link>
        <description>Updates for Graftty.</description>
        <language>en</language>
    </channel>
</rss>
```

- [ ] **Step 2: Commit**

```bash
git add appcast.xml
git commit -m "feat(appcast): seed appcast.xml feed (UPDATE-2.1)"
```

---

## Task 6: UpdaterController — state and public API (TDD)

**Files:**
- Create: `Sources/GrafttyKit/Updater/UpdaterController.swift`
- Create: `Tests/GrafttyKitTests/Updater/UpdaterControllerStateTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/Updater/UpdaterControllerStateTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("UpdaterController state")
@MainActor
struct UpdaterControllerStateTests {

    // The Sparkle wiring is skipped in tests (`forTesting()` constructs a
    // controller without an `SPUUpdater`). Tests drive the published
    // state directly via the internal `notify…` hooks that the real
    // delegate methods call in the live path. This verifies the contract
    // the UI depends on: badge visibility and advertised version.

    @Test func startsWithNoUpdate() {
        let c = UpdaterController.forTesting()
        #expect(c.updateAvailable == false)
        #expect(c.availableVersion == nil)
    }

    @Test func scheduledDiscoveryMakesBadgeVisible() {
        let c = UpdaterController.forTesting()
        c.notifyPendingUpdateDiscovered(version: "0.3.0")
        #expect(c.updateAvailable == true)
        #expect(c.availableVersion == "0.3.0")
    }

    @Test func clearResetsState() {
        let c = UpdaterController.forTesting()
        c.notifyPendingUpdateDiscovered(version: "0.3.0")
        c.notifyPendingUpdateCleared()
        #expect(c.updateAvailable == false)
        #expect(c.availableVersion == nil)
    }

    @Test func secondScheduledDiscoveryReplacesVersion() {
        let c = UpdaterController.forTesting()
        c.notifyPendingUpdateDiscovered(version: "0.3.0")
        c.notifyPendingUpdateDiscovered(version: "0.3.1")
        #expect(c.availableVersion == "0.3.1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UpdaterControllerStateTests`
Expected: FAIL — `UpdaterController` not found.

- [ ] **Step 3: Implement the controller**

Create `Sources/GrafttyKit/Updater/UpdaterController.swift`:

```swift
import Foundation
import SwiftUI
import Sparkle

/// Swift-facing wrapper around `SPUStandardUpdaterController` that exposes
/// the state the titlebar badge observes.
///
/// - In live mode, the controller owns an `SPUStandardUpdaterController`
///   and registers itself as the `userDriverDelegate` (see
///   `UpdaterController+Delegate.swift`). Sparkle's scheduled checks
///   consult `standardUserDriverShouldHandleShowingScheduledUpdate` to
///   ask whether to show a modal — we return `false` so the check stays
///   silent and surfaces via the titlebar badge instead. A user click on
///   the badge calls `showPendingUpdate()`, which re-kicks
///   `updater.checkForUpdates(nil)` — this time Sparkle treats the check
///   as user-initiated and the standard driver shows its dialog.
/// - In test mode (`forTesting()`), the Sparkle machinery is not
///   instantiated. Tests call the `notify…` hooks directly.
@MainActor
public final class UpdaterController: NSObject, ObservableObject {

    @Published public private(set) var updateAvailable: Bool = false
    @Published public private(set) var availableVersion: String?

    /// Nil in test mode; populated in live mode once `start()` succeeds.
    /// The outer `Wiring` box keeps the live-mode init to a single
    /// `let`-like assignment after `super.init` so the delegate
    /// self-reference is safe.
    private var wiring: Wiring?

    struct Wiring {
        let standardController: SPUStandardUpdaterController
    }

    /// Production initializer. Wires `SPUStandardUpdaterController` with
    /// `self` as the `userDriverDelegate`, so
    /// `SPUStandardUserDriverDelegate` callbacks fire on this object.
    public override init() {
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.wiring = Wiring(standardController: controller)
    }

    /// Test-only: skips Sparkle wiring. The published state is still
    /// reachable through the `notify…` hooks.
    public static func forTesting() -> UpdaterController {
        UpdaterController(skipWiring: ())
    }

    private init(skipWiring: Void) {
        super.init()
        self.wiring = nil
    }

    public var canCheckForUpdates: Bool {
        wiring?.standardController.updater.canCheckForUpdates ?? false
    }

    /// User-initiated check via `Graftty → Check for Updates…`. Always
    /// surfaces Sparkle's standard dialog regardless of whether an
    /// update exists. When a pending scheduled-check result is waiting
    /// on us, this also resurfaces that result — `immediateFocus` will
    /// be `true`, so the delegate returns `true` and Sparkle shows the
    /// modal.
    public func checkForUpdatesWithUI() {
        wiring?.standardController.checkForUpdates(nil)
    }

    /// Invoked by the titlebar badge click. Triggers a fresh check whose
    /// `immediateFocus` flag is set — Sparkle re-surfaces the same
    /// pending update through the standard driver's modal. The appcast
    /// is re-fetched (one HTTP GET) but that cost is fine at this
    /// cadence; it also ensures the user sees the freshest version if
    /// we've raced a new release.
    public func showPendingUpdate() {
        wiring?.standardController.checkForUpdates(nil)
    }

    // MARK: - State-transition hooks called from the delegate extension

    /// Published so tests can drive state directly without faking Sparkle.
    /// The delegate extension is the only live-mode caller.
    public func notifyPendingUpdateDiscovered(version: String) {
        availableVersion = version
        updateAvailable = true
    }

    public func notifyPendingUpdateCleared() {
        availableVersion = nil
        updateAvailable = false
    }

    /// Access to the underlying updater for the delegate extension only.
    /// Internal, not public — outside code uses `checkForUpdatesWithUI`
    /// and `showPendingUpdate`.
    var underlyingUpdater: SPUUpdater? {
        wiring?.standardController.updater
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdaterControllerStateTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Updater/UpdaterController.swift \
        Tests/GrafttyKitTests/Updater/UpdaterControllerStateTests.swift
git commit -m "feat(updater): UpdaterController state + test-mode init (UPDATE-1.2, UPDATE-1.4)"
```

---

## Task 7: SPUStandardUserDriverDelegate conformance

**Files:**
- Create: `Sources/GrafttyKit/Updater/UpdaterController+Delegate.swift`

- [ ] **Step 1: Implement the delegate extension**

Create `Sources/GrafttyKit/Updater/UpdaterController+Delegate.swift`:

```swift
import Foundation
import Sparkle

/// `SPUStandardUserDriverDelegate` conformance for `UpdaterController`.
///
/// The two interesting callbacks are
/// `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`
/// and `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)`.
/// The former lets us veto Sparkle's modal alert on silent scheduled
/// checks (return `false` so Sparkle hands responsibility to us). The
/// latter tells us — whether or not we're handling it — which update is
/// about to be shown; we snapshot its version into the controller's
/// published state so the titlebar badge can render without poking at
/// Sparkle internals.
///
/// User-initiated checks (`immediateFocus == true`) are always handled
/// by the standard driver (return `true`). That makes `Graftty → Check
/// for Updates…` and badge clicks both present Sparkle's standard
/// dialog, which is the consistent UX we want.
extension UpdaterController: SPUStandardUserDriverDelegate {

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let the standard driver show the modal when the check is
        // user-initiated or the app is being immediately focused (e.g.
        // the user just came back to the app and there's a pending
        // update). Suppress it for silent background checks — the
        // titlebar badge surfaces those instead.
        return immediateFocus
    }

    public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            // Standard driver is about to show the modal for this update —
            // the badge is redundant; clear it so we don't have both UI
            // surfaces arguing about the same update. Subsequent install /
            // skip / defer choices are tracked by Sparkle's own state;
            // when the updater cycle resets on the next scheduled tick,
            // `willHandleShowingUpdate(false, …)` will re-populate the
            // badge if an update is still pending.
            notifyPendingUpdateCleared()
        } else {
            // We're responsible for surfacing this update — populate the
            // badge with the advertised version.
            notifyPendingUpdateDiscovered(version: update.displayVersionString)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: exits 0. No new warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Updater/UpdaterController+Delegate.swift
git commit -m "feat(updater): SPUStandardUserDriverDelegate — gentle scheduled reminders (UPDATE-1.2, UPDATE-1.5)"
```

---

## Task 8: UpdateBadge SwiftUI view

**Files:**
- Create: `Sources/GrafttyKit/Updater/UpdateBadge.swift`

- [ ] **Step 1: Implement the badge view**

Create `Sources/GrafttyKit/Updater/UpdateBadge.swift`:

```swift
import SwiftUI

/// Pill-shaped titlebar button visible only while `controller.updateAvailable`.
/// Clicking routes through `UpdaterController.showPendingUpdate()`, which
/// triggers a user-initiated check — Sparkle's standard driver then shows
/// its install dialog and owns the UI from there.
public struct UpdateBadge: View {
    @ObservedObject public var controller: UpdaterController

    public init(controller: UpdaterController) {
        self.controller = controller
    }

    public var body: some View {
        if controller.updateAvailable, let version = controller.availableVersion {
            Button {
                controller.showPendingUpdate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("v\(version)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.85))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Update to Graftty v\(version) available")
        } else {
            EmptyView()
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Updater/UpdateBadge.swift
git commit -m "feat(updater): SwiftUI titlebar badge view (UPDATE-1.2)"
```

---

## Task 9: UpdaterTitlebarAccessory — AppKit view controller

**Files:**
- Create: `Sources/GrafttyKit/Updater/UpdaterTitlebarAccessory.swift`

- [ ] **Step 1: Implement the accessory**

Create `Sources/GrafttyKit/Updater/UpdaterTitlebarAccessory.swift`:

```swift
import AppKit
import SwiftUI

/// `NSTitlebarAccessoryViewController` that hosts `UpdateBadge` and installs
/// itself on a window at `layoutAttribute = .leading`, which positions the
/// accessory immediately right of the traffic lights. When the badge's
/// SwiftUI view collapses (no update available), the accessory reports
/// zero intrinsic size and stays invisible — there is no need to remove
/// the accessory dynamically.
@MainActor
public final class UpdaterTitlebarAccessory: NSTitlebarAccessoryViewController {

    private let controller: UpdaterController

    public init(controller: UpdaterController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        self.layoutAttribute = .leading
        self.view = NSHostingView(rootView: UpdateBadge(controller: controller))
        self.view.translatesAutoresizingMaskIntoConstraints = false
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Attach to the given window idempotently — a second call with the
    /// same window is a no-op so re-entry from SwiftUI's `viewDidMoveToWindow`
    /// doesn't stack duplicate accessories.
    public func install(on window: NSWindow) {
        let alreadyInstalled = window.titlebarAccessoryViewControllers.contains { $0 === self }
        guard !alreadyInstalled else { return }
        window.addTitlebarAccessoryViewController(self)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Updater/UpdaterTitlebarAccessory.swift
git commit -m "feat(updater): NSTitlebarAccessoryViewController at .leading (UPDATE-1.2)"
```

---

## Task 10: WindowAccessoryInstaller — SwiftUI → NSWindow bridge

**Files:**
- Create: `Sources/Graftty/Views/WindowAccessoryInstaller.swift`

- [ ] **Step 1: Implement the installer**

Create `Sources/Graftty/Views/WindowAccessoryInstaller.swift`:

```swift
import SwiftUI
import AppKit
import GrafttyKit

/// Installs the update-badge titlebar accessory on the host `NSWindow`
/// once the view is attached. Mirrors the `NSViewRepresentable` +
/// `viewDidMoveToWindow` pattern used by `WindowBackgroundTint`.
struct WindowAccessoryInstaller: NSViewRepresentable {
    let updaterController: UpdaterController

    func makeNSView(context: Context) -> NSView {
        let view = InstallerView()
        view.updaterController = updaterController
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? InstallerView)?.updaterController = updaterController
    }

    private final class InstallerView: NSView {
        var updaterController: UpdaterController?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let controller = updaterController else { return }
            let accessory = UpdaterTitlebarAccessory(controller: controller)
            accessory.install(on: window)
        }
    }
}

extension View {
    /// Install the update-badge accessory in the host window's titlebar.
    func installUpdateBadgeAccessory(controller: UpdaterController) -> some View {
        background(WindowAccessoryInstaller(updaterController: controller))
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Views/WindowAccessoryInstaller.swift
git commit -m "feat(updater): bridge titlebar accessory into SwiftUI window (UPDATE-1.2)"
```

---

## Task 11: Wire into GrafttyApp

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`

- [ ] **Step 1: Construct `UpdaterController` as an `@StateObject`**

In `Sources/Graftty/GrafttyApp.swift`, near the existing `@StateObject private var webController: WebServerController` declaration, add:

```swift
@StateObject private var updaterController: UpdaterController
```

In the `init()` body, after `_webController = StateObject(...)`, add:

```swift
_updaterController = StateObject(wrappedValue: UpdaterController())
```

- [ ] **Step 2: Inject into MainWindow**

In `GrafttyApp.body`, the `MainWindow(...)` call site already passes several services via `.environmentObject(webController)`. Add another line:

```swift
.environmentObject(updaterController)
```

- [ ] **Step 3: Install the accessory from MainWindow**

Edit `Sources/Graftty/Views/MainWindow.swift`. Add an `@EnvironmentObject` declaration alongside `webController`:

```swift
@EnvironmentObject private var updaterController: UpdaterController
```

In the `body` of `MainWindow`, find the `.windowBackgroundTint(theme:)` call on the `NavigationSplitView`. Immediately after it (before `.preferredColorScheme(...)`), add:

```swift
.installUpdateBadgeAccessory(controller: updaterController)
```

- [ ] **Step 4: Add menu items**

In `GrafttyApp.body`'s `.commands { ... }`, locate the existing `CommandGroup(after: .appInfo) { ... }`. Prepend to its body (before `Button("Install CLI Tool...")`):

```swift
Button("Check for Updates...") {
    updaterController.checkForUpdatesWithUI()
}
.disabled(!updaterController.canCheckForUpdates)

Toggle("Automatically Check for Updates", isOn: Binding(
    get: { UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true },
    set: { UserDefaults.standard.set($0, forKey: "SUEnableAutomaticChecks") }
))

Divider()
```

Note: the "Automatically Check for Updates" toggle binds directly to Sparkle's own defaults key — Sparkle reads `SUEnableAutomaticChecks` on its own schedule, so no explicit refresh call is needed.

- [ ] **Step 5: Build and launch to smoke-test**

Run: `swift build`
Expected: exits 0.

Run: `./scripts/bundle.sh` (after Task 12 lands the Info.plist changes — for now, just verify `swift build` passes).

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/MainWindow.swift
git commit -m "feat(updater): wire UpdaterController into GrafttyApp + MainWindow (UPDATE-1.2, UPDATE-1.5)"
```

---

## Task 12: Info.plist additions in bundle.sh

**Files:**
- Modify: `scripts/bundle.sh`

- [ ] **Step 1: Add Sparkle keys to the Info.plist heredoc**

Edit `scripts/bundle.sh`. Find the Info.plist heredoc (starts with `cat > "$APP/Contents/Info.plist" <<PLIST`). Locate the line:

```xml
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
```

Add immediately after the closing `</string>`:

```xml
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/btucker/graftty/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>__SPARKLE_PUBLIC_ED_KEY__</string>
```

The literal `__SPARKLE_PUBLIC_ED_KEY__` is a deploy-time sentinel. The one-time setup (documented in Task 14) runs `generate_keys` and substitutes the base64 public key into this line once. Subsequent releases never rewrite it — the public key never rotates for the lifetime of the keypair.

- [ ] **Step 2: Build the bundle end-to-end**

Run: `./scripts/bundle.sh`
Expected: exits 0, produces `.build/Graftty.app`. `plutil -lint` should succeed on `Contents/Info.plist`:

```bash
plutil -lint .build/Graftty.app/Contents/Info.plist
```

Expected: `Contents/Info.plist: OK`.

- [ ] **Step 3: Verify the keys are present**

```bash
plutil -p .build/Graftty.app/Contents/Info.plist | grep -E 'SUFeedURL|SUPublicEDKey'
```

Expected: both keys present.

- [ ] **Step 4: Commit**

```bash
git add scripts/bundle.sh
git commit -m "build: seed SUFeedURL and SUPublicEDKey placeholder in bundle.sh (UPDATE-*)"
```

---

## Task 13: Release workflow — sign + commit appcast

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Insert sign + appcast-update steps**

Edit `.github/workflows/release.yml`. Find the `Zip artifact` step. Immediately after it (before `Create GitHub release`), insert:

```yaml
      - name: Build Sparkle sign_update
        run: |
          set -euo pipefail
          # Clone Sparkle at the same version our SwiftPM package
          # resolves to. Package.resolved is the source of truth.
          SPARKLE_VERSION="$(jq -r '.pins[] | select(.identity=="sparkle") | .state.version' Package.resolved)"
          git clone --depth 1 --branch "$SPARKLE_VERSION" \
            https://github.com/sparkle-project/Sparkle.git /tmp/sparkle
          (cd /tmp/sparkle && swift build -c release --product sign_update)
          cp /tmp/sparkle/.build/release/sign_update ./sign_update

      - name: Sign release zip
        id: sign
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
          ZIP: ${{ steps.zip.outputs.zip }}
        run: |
          set -euo pipefail
          if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
            echo "SPARKLE_ED_PRIVATE_KEY secret is not set" >&2
            exit 1
          fi
          ED_SIGNATURE="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | ./sign_update --ed-key-file - "$ZIP")"
          LENGTH="$(stat -f %z "$ZIP")"
          echo "ed_signature=$ED_SIGNATURE" >> "$GITHUB_OUTPUT"
          echo "length=$LENGTH" >> "$GITHUB_OUTPUT"

      - name: Fetch release notes for appcast
        id: notes
        env:
          GH_TOKEN: ${{ github.token }}
          VERSION: ${{ steps.version.outputs.version }}
        run: |
          set -euo pipefail
          NOTES_FILE="$(mktemp)"
          gh release view "v$VERSION" --json body --jq '.body' > "$NOTES_FILE"
          echo "notes_file=$NOTES_FILE" >> "$GITHUB_OUTPUT"

      - name: Update appcast on main
        env:
          VERSION: ${{ steps.version.outputs.version }}
          ZIP: ${{ steps.zip.outputs.zip }}
          ED_SIGNATURE: ${{ steps.sign.outputs.ed_signature }}
          LENGTH: ${{ steps.sign.outputs.length }}
          NOTES_FILE: ${{ steps.notes.outputs.notes_file }}
        run: |
          set -euo pipefail
          # Build the appcast-updater tool from the pinned source tree
          # that produced the release.
          swift build -c release --product appcast-updater
          UPDATER="$(swift build -c release --show-bin-path)/appcast-updater"

          # Work in a checkout of main so the push goes straight to the
          # default branch. The release workflow triggers on tag push so
          # HEAD is the tag, not main.
          git clone "https://x-access-token:${{ github.token }}@github.com/${{ github.repository }}.git" main-checkout
          cd main-checkout
          git checkout main

          "$UPDATER" \
            --feed appcast.xml \
            --version "$VERSION" \
            --download-url "https://github.com/${{ github.repository }}/releases/download/v$VERSION/$ZIP" \
            --length "$LENGTH" \
            --ed-signature "$ED_SIGNATURE" \
            --minimum-system-version "14.0" \
            --release-notes "$NOTES_FILE"

          git config user.name  "graftty-release-bot"
          git config user.email "graftty-release-bot@users.noreply.github.com"
          git add appcast.xml
          if git diff --cached --quiet; then
            echo "Appcast unchanged — idempotent re-run or same-version re-release"
            exit 0
          fi
          git commit -m "appcast: v$VERSION"
          git push origin main
```

- [ ] **Step 2: Validate the workflow YAML**

Run:

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"
```

Expected: exits 0 (no parse error).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci(release): sign zip + commit appcast on main after release (UPDATE-2.1)"
```

---

## Task 14: One-time setup docs

**Files:**
- Modify: `docs/release/README.md`
- Modify: `docs/release/Casks/graftty.rb`

- [ ] **Step 1: Add `auto_updates true` to the cask template**

Edit `docs/release/Casks/graftty.rb`. Find the `version "..."` line. Immediately after the `sha256 "..."` line that follows, add:

```ruby
  auto_updates true
```

- [ ] **Step 2: Document the Sparkle setup in the release README**

Edit `docs/release/README.md`. Locate the existing `## One-time setup` section (around lines 9-49). Append a new subsection at the end of that section (before `### Keeping the cask in sync`):

````markdown
### 4. Generate the Sparkle EdDSA keypair

Sparkle verifies every update download against a public key baked into
the app bundle. The private half signs release zips in CI.

```bash
brew install --cask sparkle          # one-time; installs generate_keys + sign_update
generate_keys                        # stores the keypair in the Keychain
generate_keys -p                     # prints the base64 public key
generate_keys -x ~/sparkle-private.key  # exports the private key to a file
```

**Wire the public key into bundle.sh.** Open `scripts/bundle.sh`, find
the `__SPARKLE_PUBLIC_ED_KEY__` sentinel inside the Info.plist heredoc,
and replace it with the output of `generate_keys -p`. Commit:

```bash
git add scripts/bundle.sh
git commit -m "build: install Sparkle public key"
```

**Wire the private key into CI.** On GitHub, go to Settings → Secrets
and variables → Actions → New repository secret. Name it
`SPARKLE_ED_PRIVATE_KEY`. The value is the contents of
`~/sparkle-private.key` (one base64 line).

**Guard the private key.** After setting the GitHub secret, back the
file up somewhere safe (password manager, offline drive) and then shred
it from the working copy:

```bash
rm -P ~/sparkle-private.key
```

Losing both the Keychain copy and the backup means every user has to
manually re-download a new build — there is no recovery path.

### 5. Flip `auto_updates true` in the tap

The release workflow only rewrites `version` and `sha256` in the tap's
copy of `Casks/graftty.rb`. Adding the `auto_updates true` stanza is a
one-time manual sync:

```bash
cd /tmp/homebrew-graftty   # or wherever your checkout lives
git pull
# Edit Casks/graftty.rb to add  `auto_updates true`  after the sha256 line.
git add Casks/graftty.rb
git commit -m "cask: declare auto_updates true (Sparkle owns updates)"
git push
```

Once this lands, `brew upgrade --cask graftty` on a machine with an
up-to-date Sparkle-installed build becomes a no-op instead of
reinstalling a possibly-older cask version.
````

- [ ] **Step 3: Commit**

```bash
git add docs/release/README.md docs/release/Casks/graftty.rb
git commit -m "docs(release): document Sparkle EdDSA setup + auto_updates cask flag (UPDATE-*)"
```

---

## Task 15: SPECS.md additions

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Find the right insertion point**

Use `grep -n "^## 16. Keyboard Shortcuts" SPECS.md` to locate the Keyboard Shortcuts header. The new `UPDATE-*` section goes immediately before it.

- [ ] **Step 2: Insert the new section**

Insert the following block above `## 16. Keyboard Shortcuts`:

```markdown
## 15A. Self-Update

### 15A.1 Automatic checks

**UPDATE-1.1** While the user has consented to automatic checks (Sparkle
default: on, toggleable via `Graftty → Automatically Check for Updates`),
the application shall query `https://raw.githubusercontent.com/btucker/graftty/main/appcast.xml`
once per 24 hours.

**UPDATE-1.6** If the user has not yet chosen a preference for automatic
checks, on first launch the application shall prompt once (Sparkle's
built-in consent dialog) and persist the choice under Sparkle's own
`SUEnableAutomaticChecks` user-default key.

### 15A.2 Gentle discovery

**UPDATE-1.2** When a scheduled check discovers a newer version, the
application shall surface a non-modal indicator in the window titlebar
(immediately right of the traffic lights) rather than presenting a modal
dialog.

**UPDATE-1.4** While no update is available, the application shall hide
the titlebar indicator entirely.

### 15A.3 Install flow

**UPDATE-1.3** When the user clicks the titlebar indicator, the
application shall present Sparkle's standard install dialog with
Install Now / Install on Quit / Release Notes / Skip This Version
options.

**UPDATE-1.5** When the user selects `Graftty → Check for Updates…`,
the application shall perform an immediate check and present Sparkle's
standard dialog regardless of whether a newer version exists.

**UPDATE-1.7** When an update is installed, the application shall
relaunch and re-attach to existing zmx-backed terminal sessions so
shells running inside them are preserved.

### 15A.4 Release pipeline

**UPDATE-2.1** When a new version tag is pushed, the release workflow
shall generate an EdDSA signature over the release zip, prepend a new
entry to `appcast.xml` on `main`, and commit that change with the
`graftty-release-bot` identity.

**UPDATE-2.2** The Homebrew cask shall declare `auto_updates true` so
`brew upgrade` does not reinstall a version older than the one Sparkle
has applied in-place.
```

- [ ] **Step 3: Commit**

```bash
git add SPECS.md
git commit -m "docs(specs): add UPDATE-1/2 self-update requirements"
```

---

## Task 16: README note

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a self-update note under Installing**

Edit `README.md`. Find the `## Installing` section (starts around line 15). Immediately before `## Building`, append:

```markdown
Graftty updates itself. On first launch, you'll be asked whether
Graftty may check for updates automatically — if you agree, a small
indicator appears in the window titlebar when a new version is
available, and clicking it installs the update. You can also trigger a
check manually from `Graftty → Check for Updates…`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): mention in-app self-update"
```

---

## Task 17: Final build + test + bundle smoke

**Files:** (none — verification only)

- [ ] **Step 1: Full build**

Run: `swift build`
Expected: exits 0, no warnings.

- [ ] **Step 2: Full test run**

Run: `swift test`
Expected: all tests PASS. New `AppcastUpdaterTests` and `UpdaterControllerStateTests` suites run.

- [ ] **Step 3: Bundle + lint**

Run: `./scripts/bundle.sh`
Expected: produces `.build/Graftty.app`.

Run: `plutil -lint .build/Graftty.app/Contents/Info.plist`
Expected: OK.

Run: `plutil -p .build/Graftty.app/Contents/Info.plist | grep -E 'SUFeedURL|SUPublicEDKey'`
Expected: both keys present (value of SUPublicEDKey is still `__SPARKLE_PUBLIC_ED_KEY__` until one-time setup runs — that's expected for this PR; the PR description flags it as a deploy-time followup).

- [ ] **Step 4: Codesign verify**

Run: `codesign --verify --strict --verbose=2 .build/Graftty.app`
Expected: `valid on disk`, `satisfies its Designated Requirement`.

- [ ] **Step 5: Manual launch**

Run: `open .build/Graftty.app`
Expected: app launches. No Sparkle errors in Console. A launch without user having set `SUEnableAutomaticChecks` presents Sparkle's consent dialog — click through it.

`Graftty` menu should contain `Check for Updates…` and `Automatically Check for Updates`.

No visible badge (no newer version exists in the real appcast), so the titlebar strip looks unchanged from before.

- [ ] **Step 6: No commit** — this is a verification task.

---

## Manual deploy steps (not part of this PR, documented for the human)

After this PR lands on `main`, one-time deployment work is required
before the first user-observable self-update works:

1. `generate_keys` locally; paste the public key into `scripts/bundle.sh`
   replacing `__SPARKLE_PUBLIC_ED_KEY__`; commit; push; PR & merge.
2. Set `SPARKLE_ED_PRIVATE_KEY` secret on the GitHub repo.
3. Add `auto_updates true` to the tap's `Casks/graftty.rb`, commit, push.
4. Cut the first release tag (`git tag vX.Y.Z && git push origin vX.Y.Z`).
   The release workflow signs the zip, commits a new entry to
   `appcast.xml`, bumps the cask. Users on earlier versions still need
   one manual `brew upgrade --cask graftty` to pick up a build with
   Sparkle — after that, the in-app updater takes over.

This sequence is mirrored in `docs/release/README.md` for future-self
reference.
