import Foundation

/// Accessors for the Phase 2 web client bundled via
/// `resources: [.copy("Web/Resources")]`. Task 1's SPM layout
/// relocates resource files to the bundle root, so lookups use
/// `Bundle.module.url(forResource:withExtension:)` with no
/// `subdirectory:` argument.
public enum WebStaticResources {

    public enum Error: Swift.Error {
        case missingResource(String)
    }

    /// Maps a URL path (e.g., "/", "/xterm.min.js") to its bundled data
    /// and content type.
    public struct Asset {
        public let contentType: String
        public let data: Data

        public init(contentType: String, data: Data) {
            self.contentType = contentType
            self.data = data
        }
    }

    public static func asset(for urlPath: String) throws -> Asset {
        let name: String
        let contentType: String
        switch urlPath {
        case "/", "/index.html":
            name = "index.html"
            contentType = "text/html; charset=utf-8"
        case "/xterm.min.js":
            name = "xterm.min.js"
            contentType = "application/javascript; charset=utf-8"
        case "/xterm.min.css":
            name = "xterm.min.css"
            contentType = "text/css; charset=utf-8"
        case "/xterm-addon-fit.min.js":
            name = "xterm-addon-fit.min.js"
            contentType = "application/javascript; charset=utf-8"
        default:
            throw Error.missingResource(urlPath)
        }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext) else {
            throw Error.missingResource(name)
        }
        let data = try Data(contentsOf: url)
        return Asset(contentType: contentType, data: data)
    }
}
