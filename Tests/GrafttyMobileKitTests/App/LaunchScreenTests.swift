import Foundation
import Testing

@Suite
struct LaunchScreenTests {

    @Test("""
@spec IOS-3.4: During pre-main launch, the application's `LaunchScreen.storyboard` shall render a uniform `systemGroupedBackgroundColor` background with no foreground image and no branded color, so the visual transition from pre-main into the first frame is seamless. The first visible frame after pre-main is the lock overlay (`IOS-3.1`), which paints `.regularMaterial` over the host picker's `List` (whose default background is `systemGroupedBackground`). Matching the launch backdrop to the post-launch lock state's underlying color eliminates the launch → blur → list color flash that a branded launch image would otherwise introduce. Per Apple's HIG, the launch screen is a shell that resembles the first screen, not a branding splash.
""")
    func launchScreenUsesPlainSystemGroupedBackground() throws {
        let storyboard = try String(contentsOf: launchScreenURL(), encoding: .utf8)

        #expect(storyboard.contains("systemGroupedBackgroundColor"))
        #expect(!storyboard.contains("image=\"LaunchImage\""))
        #expect(!storyboard.contains("name=\"AccentColor\""))
        #expect(!storyboard.contains("<image "))
    }

    private func launchScreenURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Apps/GrafttyMobile/GrafttyMobile/LaunchScreen.storyboard")
    }
}
