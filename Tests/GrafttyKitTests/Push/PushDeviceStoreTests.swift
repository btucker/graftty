import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
@spec PUSH-1.3: The Mac shall persist device registrations at `~/Library/Application Support/Graftty/push-devices.json` as `[{token, deviceName, platform, lastRegisteredAt}]`, written atomically on each mutation; records with `lastRegisteredAt > 90 days` shall be filtered out on read.
""")
struct PushDeviceStoreTests {
    private func makeTempStore() -> (PushDeviceStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("push-devices-\(UUID()).json")
        return (PushDeviceStore(fileURL: url), url)
    }

    @Test func roundTripsRegisteredDevice() throws {
        let (store, _) = makeTempStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dev = PushDevice(token: "deadbeef", deviceName: "iPhone", platform: "ios", lastRegisteredAt: now)
        try store.register(dev)
        #expect(store.liveDevices(now: now) == [dev])
    }

    @Test func filtersDevicesOlderThan90Days() throws {
        let (store, _) = makeTempStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = PushDevice(token: "stale", deviceName: "Old", platform: "ios",
                               lastRegisteredAt: now.addingTimeInterval(-91 * 86_400))
        let fresh = PushDevice(token: "fresh", deviceName: "New", platform: "ios", lastRegisteredAt: now)
        try store.register(stale)
        try store.register(fresh)
        let live = store.liveDevices(now: now)
        #expect(live.map(\.token) == ["fresh"])
    }

    @Test func replacingTokenUpdatesLastRegisteredAt() throws {
        let (store, _) = makeTempStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(60)
        try store.register(PushDevice(token: "tok", deviceName: "A", platform: "ios", lastRegisteredAt: t0))
        try store.register(PushDevice(token: "tok", deviceName: "B", platform: "ios", lastRegisteredAt: t1))
        let devices = store.liveDevices(now: t1)
        #expect(devices.count == 1)
        #expect(devices[0].deviceName == "B")
        #expect(devices[0].lastRegisteredAt == t1)
    }

    @Test func removeDropsToken() throws {
        let (store, _) = makeTempStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.register(PushDevice(token: "gone", deviceName: "X", platform: "ios", lastRegisteredAt: now))
        try store.remove(token: "gone")
        #expect(store.liveDevices(now: now).isEmpty)
    }

    @Test func atomicReplaceOnEachWrite() throws {
        let (store, url) = makeTempStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.register(PushDevice(token: "a", deviceName: "A", platform: "ios", lastRegisteredAt: now))
        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder.iso8601().decode([PushDevice].self, from: data)
        #expect(decoded.map(\.token) == ["a"])
    }
}
