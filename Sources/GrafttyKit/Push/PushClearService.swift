import Foundation

public actor PushClearService {
    private let topic: String
    private let deviceStore: PushDeviceStore
    private let dedupe: PushDedupeStore
    private let sender: ApnsFanoutSender

    public init(topic: String, deviceStore: PushDeviceStore,
                dedupe: PushDedupeStore, sender: ApnsFanoutSender) {
        self.topic = topic
        self.deviceStore = deviceStore
        self.dedupe = dedupe
        self.sender = sender
    }

    public func attentionCleared(worktreePath: String, attentionTimestamp: Date) async {
        guard dedupe.lastPushed(forWorktree: worktreePath) == attentionTimestamp else { return }
        let env: ApnsEnvelope
        do {
            env = try ApnsEnvelope.clear(topic: topic, worktreePath: worktreePath,
                                         attentionTimestamp: attentionTimestamp)
        } catch {
            return
        }
        let devices = deviceStore.liveDevices()
        guard !devices.isEmpty else { return }
        _ = await sender.sendFanout(env, to: devices)
    }
}
