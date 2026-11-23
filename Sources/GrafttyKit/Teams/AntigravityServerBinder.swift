import Foundation

/// Finds the local agent server of an `agy` process launched through
/// Graftty's wrapper and stores what native delivery needs to reach it.
///
/// AGY passes hooks neither its server address nor its credential, so the
/// wrapper chooses the credential and exports a copy hooks can read, and the
/// port is found among the provider process's listening sockets.
public struct AntigravityServerBinder: Sendable {
    /// The wrapper's hook-readable copy of the credential it gave `agy` in
    /// `ANTIGRAVITY_SERVER_CSRF_TOKEN`, which AGY withholds from hooks.
    public static let tokenEnvironmentKey = "GRAFTTY_ANTIGRAVITY_SERVER_TOKEN"

    let tokenDirectory: URL
    let listeningPorts: @Sendable (Int32) -> [Int]
    let servesConversation: @Sendable (_ conversationID: String, _ port: Int, _ token: String) -> Bool
    let isAlive: @Sendable (Int32) -> Bool

    public init(
        tokenDirectory: URL = Self.defaultTokenDirectory(),
        listeningPorts: @escaping @Sendable (Int32) -> [Int] = {
            ProcessListeningPortReader.listeningTCPPorts(ofPID: $0)
        },
        servesConversation: @escaping @Sendable (String, Int, String) -> Bool = {
            AntigravityAgentClient.servesConversation($0, port: $1, token: $2)
        },
        isAlive: @escaping @Sendable (Int32) -> Bool = { TeamPresenceMonitor.kernelIsAlive($0) }
    ) {
        self.tokenDirectory = tokenDirectory
        self.listeningPorts = listeningPorts
        self.servesConversation = servesConversation
        self.isAlive = isAlive
    }

    public static func defaultTokenDirectory() -> URL {
        AppState.defaultDirectory.appendingPathComponent("antigravity-servers", isDirectory: true)
    }

    /// @spec AGENT-6.175
    public func bind(pid: Int32, conversationID: String, token: String?) -> TeamAgentTransport? {
        guard let token, !token.isEmpty,
              let port = listeningPorts(pid).first(where: { servesConversation(conversationID, $0, token) }),
              let tokenPath = try? store(token, pid: pid) else { return nil }
        return .antigravity(port: port, conversationID: conversationID, tokenPath: tokenPath)
    }

    public static func readToken(atPath path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The credential drives the provider's whole local server, so it is
    /// kept out of presence records in a file only the user can read.
    private func store(_ token: String, pid: Int32) throws -> String {
        let files = FileManager.default
        try files.createDirectory(
            at: tokenDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for name in (try? files.contentsOfDirectory(atPath: tokenDirectory.path)) ?? [] {
            guard name.hasSuffix(".token"), let owner = Int32(name.dropLast(".token".count)),
                  owner != pid, !isAlive(owner) else { continue }
            try? files.removeItem(at: tokenDirectory.appendingPathComponent(name))
        }
        let url = tokenDirectory.appendingPathComponent("\(pid).token")
        try? files.removeItem(at: url)
        guard files.createFile(
            atPath: url.path,
            contents: Data(token.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        return url.path
    }
}
