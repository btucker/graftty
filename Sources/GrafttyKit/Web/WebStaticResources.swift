import Foundation

/// Accessors for the web client bundled via `resources: [.copy("Web/Resources")]`.
/// SPM's copy layout relocates resource files to the bundle root, so lookups use
/// `Bundle.module.url(forResource:withExtension:)` with no `subdirectory:` argument.
public enum WebStaticResources {

    public enum Error: Swift.Error {
        case missingResource(String)
    }

    public struct Asset {
        public let contentType: String
        public let data: Data

        public init(contentType: String, data: Data) {
            self.contentType = contentType
            self.data = data
        }
    }

    public static func asset(for urlPath: String) throws -> Asset {
        let filename = try resolveFilename(urlPath)
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext) else {
            throw Error.missingResource(filename)
        }
        let data = try Data(contentsOf: url)
        return Asset(contentType: contentType(forExtension: ext), data: data)
    }

    /// The bundled `index.html` body — used by the SPA fallback in `WebServer`
    /// so unknown non-`/ws` paths resolve to the client's routing entry point.
    public static func indexHTML() throws -> Asset {
        try asset(for: "/")
    }

    private static func resolveFilename(_ urlPath: String) throws -> String {
        switch urlPath {
        case "/", "/index.html": return "index.html"
        case "/app.js":          return "app.js"
        case "/app.css":         return "app.css"
        default: throw Error.missingResource(urlPath)
        }
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js":   return "application/javascript; charset=utf-8"
        case "css":  return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        default:     return "application/octet-stream"
        }
    }
}
