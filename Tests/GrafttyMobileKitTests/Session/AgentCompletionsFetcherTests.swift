#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("@spec IOS-6.35: When an iOS agent picker opens, the application shall load the terminal-owning host's agent catalog using its worktree identifier over its paired management connection or its configured HTTP API, preserve remote candidate addresses, and report failures without falling back from a paired connection to HTTP.")
struct AgentCompletionsFetcherTests {
    @Test func targetedCatalogUsesOpaqueWorktreeIdentity() throws {
        let path = "graftty-remote://device/path with spaces#worktree&query"
        #expect(AgentCompletionsFetcher.managementRequest(worktreePath: path)
                == .worktreeAgentCompletions(worktreeID: path))
        #expect(AgentCompletionsFetcher.managementRequest(worktreePath: nil) == .agentCompletions)
        let request = try AgentCompletionsFetcher.request(
            baseURL: URL(string: "https://completion.test/proxy/api/")!, worktreePath: path
        )
        let url = try #require(request.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                == [URLQueryItem(name: "worktree", value: path)])
    }
    @Test func requestPreservesProxyPrefix() throws {
        let request = try AgentCompletionsFetcher.request(baseURL: URL(string: "https://completion.test/proxy/api/")!)
        #expect(request.url?.absoluteString == "https://completion.test/proxy/api/agent-completions")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func managementPreservesAddressesAndRejectsUnexpectedResponse() throws {
        let entry = completionFixture
        #expect(try AgentCompletionsFetcher.candidates(from: .agentCompletions([entry])) == [entry])
        #expect(throws: AgentCompletionsFetcher.FetchError.invalidResponse) {
            try AgentCompletionsFetcher.candidates(from: .ok)
        }
    }

    @Test func unavailablePairNeverFallsBackToHTTP() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: RelayedWorktreeManagementClient.ClientError.self) {
            try await AgentCompletionsFetcher.fetch(
                baseURL: URL(string: "https://completion.test/api/")!,
                provider: { nil }, session: session
            )
        }
    }

    @Test func httpCatalogPreservesRemoteIdentity() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let entries = try await AgentCompletionsFetcher.fetch(
            baseURL: URL(string: "https://completion.test/api/")!, provider: nil, session: session
        )
        #expect(entries == [completionFixture])
    }

    @Test func httpFailureIsReported() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: AgentCompletionsFetcher.FetchError.http(403)) {
            try await AgentCompletionsFetcher.fetch(
                baseURL: URL(string: "https://completion.test/forbidden/")!, provider: nil, session: session
            )
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private var completionFixture: AgentCompletionCandidate {
    .init(address: "graftty-mac://device/remote/project#codex", projectPath: "/remote",
          projectName: "Remote", worktreePath: "/remote/project", worktreeName: "project",
          hostName: "Remote Mac", runtime: "codex")
}

private final class CompletionURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "completion.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status = url.path.contains("forbidden") ? 403 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode([completionFixture]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
