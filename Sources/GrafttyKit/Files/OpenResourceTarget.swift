import Foundation

public enum OpenResourceTarget {
    public static func resolve(_ text: String) throws -> URL {
        if text.contains("://") {
            guard let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else {
                throw Failure.unsupportedURL
            }
            return url
        }
        return URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
    }

    public enum Failure: LocalizedError {
        case unsupportedURL
        public var errorDescription: String? { "Use a file path or an HTTP(S) URL without embedded credentials." }
    }
}
