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
