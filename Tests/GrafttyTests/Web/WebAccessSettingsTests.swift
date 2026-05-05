import Foundation
import Testing
@testable import Graftty

@Suite("WebAccessSettings")
struct WebAccessSettingsTests {

    @MainActor
    @Test("""
    @spec WEB-1.4: The feature shall be off by default.
    """)
    func webAccessIsDisabledByDefault() {
        UserDefaults.standard.removeObject(forKey: "WebAccessEnabled")

        let settings = WebAccessSettings()

        #expect(settings.isEnabled == false)
    }
}
