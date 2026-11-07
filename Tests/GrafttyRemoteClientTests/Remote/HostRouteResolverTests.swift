import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyRemoteClient

@Suite("Automatic host routes")
@MainActor
struct HostRouteResolverTests {
    typealias Resolver = HostRouteResolver<String>
    private func peer(_ name: String, key: UInt8 = 1) throws -> RemoteMacConnectionSummary.ID {
        .init(deviceID: .init(value: name), fingerprint: try .init(rawBytes: Data(repeating: key, count: 32)))
    }
    private func summary(_ peer: RemoteMacConnectionSummary.ID, state: RemoteMacConnectionSummary.State) -> RemoteMacConnectionSummary {
        .init(deviceID: peer.deviceID, fingerprint: peer.fingerprint, label: peer.deviceID.value, lastKnownHost: nil, state: state)
    }

    @Test("@spec REMOTE-13.56: When Mac or mobile opens a host with several available paths, the application shall try its paired direct connection before any relay, even when a relay was used previously.")
    func directAlwaysPrecedesRelay() async throws {
        let destination = try peer("lan-mac")
        let gateway = Resolver.Host(id: "gateway", peer: try peer("tailscale-mac"))
        let direct = Resolver.Host(id: "direct", peer: destination)
        let resolver = Resolver(pollAttempts: 2, sleep: {})
        var calls: [String] = []
        let route = try await resolver.resolve(target: .init(destination), hosts: [gateway, direct], connect: { host in
            calls.append(host.id)
        }, send: { _, _ in Issue.record("Healthy direct route must not probe a relay"); return .ok })
        #expect(route.host == direct)
        #expect(route.isDirect)
        #expect(calls == ["direct"])
    }

    @Test("@spec REMOTE-13.57: If a direct host connection fails, then Mac and mobile shall try paired intermediary Macs, reconnect the destination through a matching saved pairing, and wait for that relay to become connected without repeating the reconnect request.")
    func tailscaleGatewayReconnectsLANMac() async throws {
        let destination = try peer("lan-mac")
        let gateway = Resolver.Host(id: "gateway", peer: try peer("tailscale-mac"))
        let direct = Resolver.Host(id: "direct", peer: destination)
        let resolver = Resolver(pollAttempts: 3, sleep: {})
        var calls: [String] = []
        var lists = 0
        var reconnects = 0
        let route = try await resolver.resolve(target: .init(destination), hosts: [direct, gateway], connect: { host in
            calls.append(host.id)
            if host.id == direct.id { throw URLError(.cannotConnectToHost) }
        }, send: { host, request in
            #expect(host == gateway)
            switch request {
            case .listRemoteMacConnections:
                lists += 1
                return .remoteMacConnections([summary(destination, state: lists == 1 ? .offline : lists == 2 ? .connecting : .connected)])
            case .connectRemoteMac(let device, let fingerprint):
                #expect(device == destination.deviceID)
                #expect(fingerprint == destination.fingerprint)
                reconnects += 1
                return .ok
            default: Issue.record("Unexpected request"); return .ok
            }
        })
        #expect(calls == ["direct", "gateway"])
        #expect(route.host == gateway)
        #expect(route.destination == destination)
        #expect(!route.isDirect)
        #expect(reconnects == 1)
        #expect(lists == 3)
    }

    @Test("An unusable relay falls through to another paired intermediary")
    func triesAlternateRelayAfterTimeout() async throws {
        let destination = try peer("lan-mac")
        let first = Resolver.Host(id: "first", peer: try peer("gateway-a"))
        let second = Resolver.Host(id: "second", peer: try peer("gateway-b"))
        let resolver = Resolver(pollAttempts: 1, sleep: {})
        var connections: [String] = []
        var reconnects: [String] = []
        let route = try await resolver.resolve(target: .init(destination), hosts: [first, second], connect: { connections.append($0.id) }, send: { host, request in
            if case .connectRemoteMac = request { reconnects.append(host.id); return .ok }
            return .remoteMacConnections([summary(destination, state: host.id == "first" ? .offline : .connected)])
        })
        #expect(connections == ["first", "second"])
        #expect(reconnects == ["first"])
        #expect(route.host == second)
    }

    @Test("@spec REMOTE-13.58: When a relay reports a destination with a different saved fingerprint or a pairing-required state, the application shall reject that path without initiating a downstream connection.", arguments: [false, true])
    func rejectsMismatchedOrRevokedPairing(needsPairing: Bool) async throws {
        let destination = try peer("lan-mac")
        let reported = try peer("lan-mac", key: needsPairing ? 1 : 2)
        let gateway = Resolver.Host(id: "gateway", peer: try peer("tailscale-mac"))
        let resolver = Resolver(pollAttempts: 1, sleep: {})
        await #expect(throws: Resolver.Failure.self) {
            _ = try await resolver.resolve(target: .init(destination), hosts: [gateway], connect: { _ in }, send: { _, request in
                #expect(request == .listRemoteMacConnections)
                return .remoteMacConnections([summary(reported, state: needsPairing ? .needsPairing : .offline)])
            })
        }
    }

    @Test("Cancellation stops route exploration without connecting another host")
    func cancellationDoesNotTryRelay() async throws {
        let destination = try peer("lan-mac")
        let hosts = [Resolver.Host(id: "direct", peer: destination), Resolver.Host(id: "gateway", peer: try peer("tailscale-mac"))]
        var calls: [String] = []
        await #expect(throws: CancellationError.self) {
            _ = try await Resolver(sleep: {}).resolve(target: .init(destination), hosts: hosts, connect: { host in
                calls.append(host.id)
                throw CancellationError()
            }, send: { _, _ in Issue.record("Cancelled request continued"); return .ok })
        }
        #expect(calls == ["direct"])
    }

    private func row(path: String, owner: RemoteDeviceID, depth: Int, stableID: String = "worker:feature") -> WorktreePanes {
        .init(path: path, displayName: "feature", repoDisplayName: "Project", displayBranch: "feature", state: .running,
              isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
              layout: .leaf(sessionName: "pane-\(path)", title: "Terminal", attentionText: nil, isBusy: false, attentionSource: nil),
              origin: .init(deviceID: owner, deviceLabel: owner.value, relayDepth: depth),
              sidebar: .init(id: stableID, projectID: "worker:project"))
    }

    @Test("@spec REMOTE-13.59: When an open or reconnect chooses another path to the same worktree, the application shall match its owner and stable worktree identity, then use the chosen path's current worktree and pane identifiers.")
    func worktreeResolutionUsesChosenPathsAliases() async throws {
        let destination = try peer("lan-mac")
        let gateway = Resolver.Host(id: "gateway", peer: try peer("tailscale-mac"))
        let direct = Resolver.Host(id: "direct", peer: destination)
        let original = row(path: "/repo/feature", owner: destination.deviceID, depth: 0)
        let relayed = row(path: "relay-worktree-xyz", owner: destination.deviceID, depth: 1)
        let resolved = try await Resolver(sleep: {}).resolveWorktree(original, source: direct, hosts: [direct, gateway], connect: { host in
            if host == direct { throw URLError(.cannotConnectToHost) }
        }, send: { _, _ in .remoteMacConnections([summary(destination, state: .connected)]) }, fetch: { _ in [relayed] })
        #expect(resolved.route.host == gateway)
        #expect(resolved.worktree.path == relayed.path)
        #expect(resolved.worktree.layout?.leaves.first?.sessionName == "pane-relay-worktree-xyz")
        #expect(resolved.worktree.path != original.path)
    }

    @Test("Matching display names or raw paths never substitute a different worktree")
    func worktreeIdentityRejectsWrongOwnerOrMetadata() throws {
        let owner = try peer("lan-mac").deviceID
        let target = row(path: "/same", owner: owner, depth: 0)
        let otherOwner = row(path: "/same", owner: .init(value: "another-mac"), depth: 0)
        let otherWorktree = row(path: "/same", owner: owner, depth: 1, stableID: "worker:other")
        #expect(WorktreeRouteIdentity.matching(target, in: [otherOwner, otherWorktree], owner: owner) == nil)
    }

    @Test("A path that fails while fetching resources falls back before dispatch")
    func failedResourceReadTriesRelay() async throws {
        let peer = try peer("lan-mac")
        let direct = Resolver.Host(id: "direct", peer: peer)
        let gateway = Resolver.Host(id: "gateway", peer: try self.peer("gateway"))
        let original = row(path: "/repo", owner: peer.deviceID, depth: 0)
        let relay = row(path: "relay-worktree", owner: peer.deviceID, depth: 1)
        var directReads = 0
        let result = try await Resolver(sleep: {}).resolveWorktree(original, source: direct, hosts: [direct, gateway], connect: { _ in }, send: { _, _ in
            .remoteMacConnections([summary(peer, state: .connected)])
        }, fetch: { host in
            if host == direct {
                directReads += 1
                if directReads > 1 { throw URLError(.networkConnectionLost) }
                return [original]
            }
            return [relay]
        })
        #expect(result.route.host == gateway)
        #expect(result.worktree.path == relay.path)
    }

    @Test("Concurrent callers share establishment and one cancellation preserves the other")
    func concurrentWaiterCancellation() async throws {
        let peer = try peer("lan-mac")
        let direct = Resolver.Host(id: "direct", peer: peer)
        let resolver = Resolver(sleep: {})
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        let connect: Resolver.Connect = { _ in
            calls += 1
            await withCheckedContinuation { gate = $0 }
        }
        let send: Resolver.Send = { _, _ in Issue.record("Direct connection should suffice"); return .ok }
        let first = Task { try await resolver.resolve(target: .init(peer), hosts: [direct], connect: connect, send: send) }
        for _ in 0..<1000 where gate == nil { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await resolver.resolve(target: .init(peer), hosts: [direct], connect: connect, send: send)
        }
        for _ in 0..<1000 where !secondStarted { await Task.yield() }
        first.cancel()
        gate?.resume()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(try await second.value.host == direct)
        #expect(calls == 1)
    }

    @Test("A missing relay projection remains retryable instead of declaring the worktree deleted")
    func missingRelayProjectionIsRetryable() async throws {
        let peer = try peer("lan-mac")
        let gateway = Resolver.Host(id: "gateway", peer: try self.peer("gateway"))
        let original = row(path: "old-relay-alias", owner: peer.deviceID, depth: 1)
        do {
            _ = try await Resolver(pollAttempts: 1, sleep: {}).resolveWorktree(original, source: gateway, hosts: [gateway],
                connect: { _ in }, send: { _, _ in .remoteMacConnections([summary(peer, state: .connected)]) }, fetch: { _ in [] })
            Issue.record("Missing gateway rows should remain unavailable")
        } catch Resolver.Failure.relayNotReady { }
        catch { Issue.record("Expected retryable relay failure, received \(error)") }
    }

    @Test("Terminal failure skips that delivery host, then a new open restores direct preference")
    func failedTerminalPathDoesNotOverrideNextOpenPreference() async throws {
        let peer = try peer("lan-mac")
        let direct = Resolver.Host(id: "direct", peer: peer)
        let gateway = Resolver.Host(id: "gateway", peer: try self.peer("gateway"))
        let original = row(path: "/repo", owner: peer.deviceID, depth: 0)
        let relayed = row(path: "relay-alias", owner: peer.deviceID, depth: 1)
        let resolver = Resolver(sleep: {})
        let send: Resolver.Send = { _, _ in .remoteMacConnections([summary(peer, state: .connected)]) }
        let fetch: Resolver.Fetch = { $0 == direct ? [original] : [relayed] }
        let recovered = try await resolver.resolveWorktree(original, source: direct, hosts: [direct, gateway], excluding: [direct.id],
            connect: { _ in }, send: send, fetch: fetch)
        #expect(recovered.route.host == gateway)
        let reopened = try await resolver.resolveWorktree(relayed, source: gateway, hosts: [direct, gateway],
            connect: { _ in }, send: send, fetch: fetch)
        #expect(reopened.route.host == direct)
        let retry = try await resolver.resolveWorktree(original, source: direct, hosts: [direct], excluding: [direct.id],
            connect: { _ in }, send: send, fetch: fetch)
        #expect(retry.route.host == direct, "Exhausted paths must become eligible on the next retry cycle")
    }

    @Test("An unrelated paired Mac cannot permanently exclude a recovered original path")
    func unusableAlternativesRetryOriginalPath() async throws {
        let peer = try peer("lan-mac")
        let direct = Resolver.Host(id: "direct", peer: peer)
        let unrelated = Resolver.Host(id: "unrelated", peer: try self.peer("unrelated"))
        let original = row(path: "/repo", owner: peer.deviceID, depth: 0)
        var attempts: [String] = []
        let recovered = try await Resolver(sleep: {}).resolveWorktree(original, source: direct, hosts: [direct, unrelated], excluding: [direct.id],
            connect: { attempts.append($0.id) }, send: { _, _ in .remoteMacConnections([]) }, fetch: { _ in [original] })
        #expect(attempts == [unrelated.id, direct.id])
        #expect(recovered.route.host == direct)
    }

    @Test("A later open retries direct after a successful relay")
    func nextOpenPrefersDirectAgain() async throws {
        let peer = try peer("lan-mac")
        let direct = Resolver.Host(id: "direct", peer: peer)
        let gateway = Resolver.Host(id: "gateway", peer: try self.peer("gateway"))
        let resolver = Resolver(sleep: {})
        var directWorks = false
        var calls: [String] = []
        let connect: Resolver.Connect = { host in
            calls.append(host.id)
            if host == direct && !directWorks { throw URLError(.cannotConnectToHost) }
        }
        let send: Resolver.Send = { _, _ in .remoteMacConnections([summary(peer, state: .connected)]) }
        #expect(try await resolver.resolve(target: .init(peer), hosts: [direct, gateway], connect: connect, send: send).host == gateway)
        directWorks = true
        #expect(try await resolver.resolve(target: .init(peer), hosts: [direct, gateway], connect: connect, send: send).host == direct)
        #expect(calls == ["direct", "gateway", "direct"])
    }
}
