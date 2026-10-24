import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GrafttyKit

@Suite("@spec REMOTE-29.8: When the AWS interruption adapter polls instance metadata, it shall use IMDSv2 without redirects or proxies, distinguish an absent notice from failed observation, and translate valid action deadlines into provider-independent interruption notices.")
struct AWSInterruptionSourceTests {
    @Test func metadataHTTPDisablesExternalConfigurationAndProxyRouting() async throws {
        let source = AWSInterruptionSource(executor: MetadataCurlExecutor())
        #expect(try await source.poll() == nil)
    }

    @Test func usesTokenAndPreservesDeadline() async throws {
        let fixture = MetadataFixture(status: 200, body: #"{"action":"terminate","time":"2026-10-23T04:00:00Z"}"#)
        let source = AWSInterruptionSource(request: { try await fixture.request($0) })
        let notice = try #require(try await source.poll())
        #expect(notice.provider == "aws")
        #expect(notice.action == .terminate)
        #expect(notice.deadline == ISO8601DateFormatter().date(from: "2026-10-23T04:00:00Z"))
        #expect(try await source.poll() == notice)
        #expect(await fixture.tokenRequests == 1)
    }

    @Test(arguments: [404, 401, 500]) func absenceIsDifferentFromFailure(status: Int) async throws {
        let fixture = MetadataFixture(status: status, body: "")
        let source = AWSInterruptionSource(request: { try await fixture.request($0) })
        if status == 404 { #expect(try await source.poll() == nil) }
        else { await #expect(throws: (any Error).self) { _ = try await source.poll() } }
        if status == 401 {
            await #expect(throws: (any Error).self) { _ = try await source.poll() }
            #expect(await fixture.tokenRequests == 2)
        }
    }

    @Test(arguments: [#"{"action":"unknown","time":"2026-10-23T04:00:00Z"}"#,
                      #"{"action":"stop","time":"tomorrow"}"#, "{}", String(repeating: "x", count: 4097)])
    func malformedNoticeFails(body: String) async throws {
        let fixture = MetadataFixture(status: 200, body: body)
        let source = AWSInterruptionSource(request: { try await fixture.request($0) })
        await #expect(throws: (any Error).self) { _ = try await source.poll() }
    }
}

private actor MetadataFixture {
    let status: Int
    let body: String
    var tokenRequests = 0
    init(status: Int, body: String) { self.status = status; self.body = body }
    func request(_ request: URLRequest) throws -> (Data, Int) {
        #expect(request.url?.host == "169.254.169.254")
        #expect(request.timeoutInterval <= 3)
        if request.httpMethod == "PUT" {
            #expect(request.url?.path == "/latest/api/token")
            #expect(request.value(forHTTPHeaderField: "X-aws-ec2-metadata-token-ttl-seconds") == "60")
            tokenRequests += 1
            return (Data("test-token".utf8), 200)
        }
        #expect(request.url?.path == "/latest/meta-data/spot/instance-action")
        #expect(request.value(forHTTPHeaderField: "X-aws-ec2-metadata-token") == "test-token")
        return (Data(body.utf8), status)
    }
}

private struct MetadataCurlExecutor: CLIExecutor {
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        #expect(command == "/usr/bin/curl")
        #expect(args.first == "--disable")
        let noProxy = try #require(args.firstIndex(of: "--noproxy"))
        #expect(args[noProxy + 1] == "*")
        #expect(!args.contains("--location"))
        #expect(!args.contains("--location-trusted"))
        #expect(args.contains("--max-filesize"))
        #expect(args.contains("--max-time"))
        return .init(stdout: args.contains("PUT") ? "test-token\n200" : "\n404", stderr: "", exitCode: 0)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}
