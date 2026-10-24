import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor AWSInterruptionSource: HostInterruptionSource {
    typealias Request = @Sendable (URLRequest) async throws -> (Data, Int)
    private let request: Request
    private var token: String?
    private var tokenDeadline: ContinuousClock.Instant = .now

    public init(executor: any CLIExecutor = CLIRunner(terminatesOnCancellation: true)) {
        let client = MetadataHTTPClient(executor: executor)
        request = { try await client.request($0) }
    }

    init(request: @escaping Request) { self.request = request }

    public func poll() async throws -> HostInterruptionNotice? {
        try Task.checkCancellation()
        if token == nil || ContinuousClock.now >= tokenDeadline {
            var query = URLRequest(url: URL(string: "http://169.254.169.254/latest/api/token")!, timeoutInterval: 2)
            query.httpMethod = "PUT"
            query.setValue("60", forHTTPHeaderField: "X-aws-ec2-metadata-token-ttl-seconds")
            let (bytes, status) = try await request(query)
            guard status == 200, (1...4096).contains(bytes.count),
                  let value = String(data: bytes, encoding: .utf8),
                  !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
                throw ProviderError("AWS metadata token is unavailable.")
            }
            token = value
            tokenDeadline = .now.advanced(by: .seconds(50))
        }
        var query = URLRequest(url: URL(string: "http://169.254.169.254/latest/meta-data/spot/instance-action")!, timeoutInterval: 2)
        query.setValue(token, forHTTPHeaderField: "X-aws-ec2-metadata-token")
        let (bytes, status) = try await request(query)
        try Task.checkCancellation()
        if status == 401 { token = nil }
        if status == 404 { return nil }
        guard status == 200, bytes.count <= 4096 else { throw ProviderError("AWS interruption observation failed.") }
        struct Payload: Decodable { let action: HostInterruptionNotice.Action; let time: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: bytes),
              let deadline = ISO8601DateFormatter().date(from: payload.time) else {
            throw ProviderError("AWS interruption notice is invalid.")
        }
        return .init(provider: "aws", eventID: payload.action.rawValue + ":" + payload.time,
                     action: payload.action, deadline: deadline)
    }
}

/// curl provides explicit proxy bypass on Linux as well as macOS. Disable its
/// configuration file and redirects so the IMDS token stays on the link-local
/// connection. AWS documents this endpoint independently of its public APIs.
private struct MetadataHTTPClient: Sendable {
    let executor: any CLIExecutor

    func request(_ query: URLRequest) async throws -> (Data, Int) {
        var arguments = ["--disable", "--silent", "--show-error", "--noproxy", "*", "--proto", "=http",
            "--connect-timeout", "1", "--max-time", "2", "--max-filesize", "4096",
            "--request", query.httpMethod ?? "GET", "--write-out", "\n%{http_code}"]
        for (name, value) in (query.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            arguments += ["--header", name + ": " + value]
        }
        arguments += ["--url", query.url!.absoluteString]
        let output: CLIOutput
        do {
            output = try await executor.run(command: "/usr/bin/curl", args: arguments, at: "/", timeout: .seconds(3))
        } catch is CancellationError { throw CancellationError() }
        catch { throw ProviderError("AWS metadata request failed; verify curl and IMDSv2 access.") }
        guard output.exitCode == 0, let separator = output.stdout.lastIndex(of: "\n"),
              let status = Int(output.stdout[output.stdout.index(after: separator)...]), (100...599).contains(status) else {
            throw ProviderError("Invalid AWS metadata HTTP result.")
        }
        return (Data(output.stdout[..<separator].utf8), status)
    }
}
