import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
@spec PUSH-5.1: When `clearAttentionIfTimestamp(_:_:)` fires on the Mac for a worktree+timestamp that was previously pushed, the application shall send a silent APNs push (`apns-push-type: background`, `aps.content-available: 1`, no `aps.alert`) with the same `apns-collapse-id` as the original alert push.
""")
struct PushClearServiceTests {
    @Test func sendsClearWhenPreviouslyPushed() async throws {
        let dedupe = PushDedupeStore()
        let path = "/r/wt"
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        dedupe.markPushed(worktree: path, attentionTimestamp: ts)
        let sender = MockEnvelopeSender()
        let store = PushDeviceStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                              .appendingPathComponent("pds-\(UUID()).json"))
        try store.register(PushDevice(token: "abc", deviceName: "iP", platform: "ios", lastRegisteredAt: Date()))
        let svc = PushClearService(topic: "com.quotably.graftty", deviceStore: store,
                                   dedupe: dedupe, sender: sender)
        await svc.attentionCleared(worktreePath: path, attentionTimestamp: ts)
        let sent = await sender.snapshot()
        #expect(sent.count == 1)
        #expect(sent[0].envelope.pushType == .background)
        // Collapse-id is `<path>:<ISO timestamp with fractional seconds>` per ApnsEnvelope.clear.
        #expect(sent[0].envelope.collapseID.hasPrefix("\(path):"))
    }

    @Test func skipsWhenNotPreviouslyPushed() async throws {
        let store = PushDeviceStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                              .appendingPathComponent("pds-\(UUID()).json"))
        let sender = MockEnvelopeSender()
        let svc = PushClearService(
            topic: "com.quotably.graftty",
            deviceStore: store,
            dedupe: PushDedupeStore(),
            sender: sender)
        await svc.attentionCleared(worktreePath: "/r/wt",
                                   attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let sent = await sender.snapshot()
        #expect(sent.isEmpty)
    }

    @Test func skipsWhenNoLiveDevices() async throws {
        let dedupe = PushDedupeStore()
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        dedupe.markPushed(worktree: "/r/wt", attentionTimestamp: ts)
        let sender = MockEnvelopeSender()
        let svc = PushClearService(
            topic: "com.quotably.graftty",
            deviceStore: PushDeviceStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pds-\(UUID()).json")),
            dedupe: dedupe,
            sender: sender)
        await svc.attentionCleared(worktreePath: "/r/wt", attentionTimestamp: ts)
        let sent = await sender.snapshot()
        #expect(sent.isEmpty)
    }
}

final actor MockEnvelopeSender: ApnsFanoutSender {
    struct Call: Sendable { let envelope: ApnsEnvelope; let devices: [PushDevice] }
    private var sentEnvelopes: [Call] = []
    func sendFanout(_ env: ApnsEnvelope, to devices: [PushDevice]) async -> [ApnsFanoutResult] {
        sentEnvelopes.append(Call(envelope: env, devices: devices))
        return devices.map { ApnsFanoutResult(device: $0, outcome: .delivered) }
    }
    func snapshot() -> [Call] { sentEnvelopes }
}
