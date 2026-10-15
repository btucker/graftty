import Testing
@testable import Graftty
import GrafttyKit

struct LinuxHostSetupFormTests {
    @Test("@spec REMOTE-21.7: While Linux host setup is running, the application shall display its current step, prevent duplicate starts, and offer cancellation; after failure it shall retain the plan for retry.")
    func formLifecycle() {
        var form = LinuxHostSetupForm()
        form.destination = "my-linux"
        form.destinationRoot = "~/projects"
        form.version = "1.2.3"
        #expect(form.canStart)
        form.start()
        #expect(!form.canStart)
        #expect(form.isRunning)
        form.update(.init(message: "Importing app", completed: 2, total: 4))
        #expect(form.progress?.message == "Importing app")
        form.fail("Repository is dirty")
        #expect(form.canStart)
        #expect(form.destination == "my-linux")
        #expect(form.destinationRoot == "~/projects")
        form.start()
        form.cancel()
        #expect(!form.canStart)
        #expect(form.isRunning)
        form.finishCancellation()
        #expect(form.canStart)
    }
}
