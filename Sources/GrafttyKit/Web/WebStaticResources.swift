import Foundation

/// Accessors for the web client bundled via `resources: [.copy("Web/Resources")]`,
/// which copies a directory literally named `Resources` into the bundle. In the
/// standard `Contents/Resources` layout (Swift 6.4's build system) it is a
/// nested `Resources/` subdirectory. Foundation resolves the same lookup in
/// SwiftPM's flat layout too, but only through undocumented handling of a
/// top-level `Resources` directory, so the unscoped lookup stays as a
/// fallback (CONFIG-2.7).
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
        try asset(for: urlPath, in: GrafttyKitResourceBundle.bundle)
    }

    static func asset(for urlPath: String, in bundle: Bundle) throws -> Asset {
        let filename = try resolveFilename(urlPath)
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext, subdirectory: "Resources")
                ?? bundle.url(forResource: base, withExtension: ext) else {
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
