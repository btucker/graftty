import Testing
import GrafttyProtocol
import Foundation
@testable import GrafttyKit

@Suite("@spec PROJECT-2.4: When origin detection resolves a repo's origin remote, the application shall publish the resolved HostingOrigin in PRStatusStore.originByRepo, omit repos whose detection returns nil, and prune entries for repos removed from the model.")
struct PRStatusStoreOriginPublishTests {

    @MainActor
    private final class ReposBox {
        var repos: [RepoEntry]
        init(_ repos: [RepoEntry]) { self.repos = repos }
    }

    private static func repoEntry(path: String) -> RepoEntry {
        RepoEntry(
            path: path,
            displayName: (path as NSString).lastPathComponent,
            worktrees: [WorktreeEntry(path: "\(path)/wt", branch: "feature/x", state: .running)]
        )
    }

    /// Store with a stubbed detector and no fetcher (PR fetching is
    /// irrelevant to origin publication). Returns the store, ticker,
    /// and the mutable repo list backing getRepos.
    @MainActor
    private static func makeStore(
        detect: @Sendable @escaping (String) async throws -> HostingOrigin?,
        repos: [RepoEntry]
    ) -> (PRStatusStore, ManualTicker, ReposBox) {
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in nil },
            detectHost: detect
        )
        let ticker = ManualTicker()
        let box = ReposBox(repos)
        store.start(ticker: ticker, getRepos: { box.repos })
        return (store, ticker, box)
    }

    @MainActor
    private static func waitForOrigin(_ store: PRStatusStore, repoPath: String) async throws {
        for _ in 0..<50 {
            if store.originByRepo[repoPath] != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func publishesResolvedOriginAfterFetch() async throws {
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")
        let (store, ticker, _) = await Self.makeStore(
            detect: { _ in origin },
            repos: [Self.repoEntry(path: "/repoA")]
        )
        await ticker.fire()
        try await Self.waitForOrigin(store, repoPath: "/repoA")
        #expect(await store.originByRepo["/repoA"] == origin)
        await MainActor.run { store.stop() }
    }

    @Test func publishesUnsupportedOriginsToo() async throws {
        // The store publishes every resolved origin; filtering
        // unsupported providers is presentation's job (PROJECT-2.2).
        let origin = HostingOrigin(provider: .unsupported, host: "bitbucket.org", owner: "foo", repo: "bar")
        let (store, ticker, _) = await Self.makeStore(
            detect: { _ in origin },
            repos: [Self.repoEntry(path: "/repoA")]
        )
        await ticker.fire()
        try await Self.waitForOrigin(store, repoPath: "/repoA")
        #expect(await store.originByRepo["/repoA"] == origin)
        await MainActor.run { store.stop() }
    }

    @Test func omitsReposWithNoOrigin() async throws {
        let (store, ticker, _) = await Self.makeStore(
            detect: { _ in nil },
            repos: [Self.repoEntry(path: "/repoA")]
        )
        await ticker.fire()
        // Poll until the in-flight Task finishes rather than sleeping a fixed
        // duration. `dispatchRepoFetch` sets `inFlightSince` synchronously
        // before spawning the Task, so after `ticker.fire()` returns the repo
        // is guaranteed to be in-flight. When `performRepoFetch` completes its
        // `defer` clears `inFlightSince`, meaning `isInFlightForTesting` false
        // reliably means the detect closure ran and returned nil — so
        // `originByRepo` is definitively empty.
        for _ in 0..<50 {
            if await !store.isInFlightForTesting("/repoA") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await store.originByRepo.isEmpty)
        await MainActor.run { store.stop() }
    }

    @Test func prunesOriginsForRemovedRepos() async throws {
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")
        let (store, ticker, box) = await Self.makeStore(
            detect: { _ in origin },
            repos: [Self.repoEntry(path: "/repoA")]
        )
        await ticker.fire()
        try await Self.waitForOrigin(store, repoPath: "/repoA")
        #expect(await store.originByRepo["/repoA"] == origin)

        await MainActor.run { box.repos = [] }
        await ticker.fire()
        #expect(await store.originByRepo.isEmpty)
        await MainActor.run { store.stop() }
    }
}
