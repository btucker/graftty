import Foundation
import GrafttyProtocol
import Testing

@Suite struct TailcatOptInTests {
    @Test("@spec REMOTE-11.31: When a user enables Tailcat on a device, the application shall persist the opt-in for paired remote connections and default to disabled on a new installation.")
    func optInIsDeviceLocalAndDefaultsOff() throws {
        let name = "tailcat-setting-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!TailcatPreference.isEnabled(in: defaults))
        defaults.set(true, forKey: TailcatPreference.key)
        let reopened = try #require(UserDefaults(suiteName: name))
        #expect(TailcatPreference.isEnabled(in: reopened))
        defaults.set(false, forKey: TailcatPreference.key)
        #expect(!TailcatPreference.isEnabled(in: defaults))
    }
}
