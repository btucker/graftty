import Foundation
import Testing
@testable import GrafttyKit

struct WorktreeSleepPreferencesTests {
    @Test("@spec SLEEP-7: When automatic sleep is configured, the application shall default to disabled with a fifteen-minute inactivity duration and persist each worktree's Keep Awake override.")
    func defaultsAndBounds() throws {
        let name = "SleepPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!defaults.bool(forKey: WorktreeSleepPreferences.enabledKey))
        #expect(WorktreeSleepPreferences.duration(defaults: defaults) == 900)
        defaults.set(-1, forKey: WorktreeSleepPreferences.minutesKey)
        #expect(WorktreeSleepPreferences.duration(defaults: defaults) == 900)
        defaults.set(5, forKey: WorktreeSleepPreferences.minutesKey)
        #expect(WorktreeSleepPreferences.duration(defaults: defaults) == 300)
        WorktreeSleepPreferences.setKeepsAwake(true, path: "/w", defaults: defaults)
        #expect(WorktreeSleepPreferences.keepsAwake("/w", defaults: defaults))
        #expect(!WorktreeSleepPreferences.keepsAwake("/other", defaults: defaults))
        WorktreeSleepPreferences.setKeepsAwake(false, path: "/w", defaults: defaults)
        #expect(!WorktreeSleepPreferences.keepsAwake("/w", defaults: defaults))
    }

    @Test("@spec SLEEP-8: While a verified task's process lifetime registration is live, the application shall keep its owning worktree awake even if the task detaches or produces no output.")
    func taskLifetime() {
        let root = SleepProcessIdentity(pid: 10, startTime: 20)
        let task = SleepProcessIdentity(pid: 11, startTime: 21)
        let record = SleepKeepAwakeRegistration(path: "/w", root: root, task: task)
        #expect(record.blocksSleep(path: "/w", startTime: { _ in 21 }))
        #expect(!record.blocksSleep(path: "/other", startTime: { _ in 21 }))
        #expect(!record.blocksSleep(path: "/w", startTime: { _ in 22 }))
        #expect(record.blocksSleep(path: "/w", startTime: { _ in nil }))
    }
}
