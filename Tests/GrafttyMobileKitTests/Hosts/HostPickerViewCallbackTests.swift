#if canImport(UIKit)
import Testing
import Foundation
@testable import GrafttyMobileKit

@MainActor
@Suite("HostPickerView callback mode")
struct HostPickerViewCallbackTests {

    @Test("onSelect: nil is the default (push-nav mode)")
    func onSelectDefaultsToNil() {
        let store = HostStore(storeURL: URL(fileURLWithPath: "/tmp/hostpickerview-default-\(UUID()).json"))
        let view = HostPickerView(store: store)
        #expect(view.onSelect == nil)
    }

    @Test("onSelect: non-nil is stored")
    func onSelectCallbackStored() {
        let store = HostStore(storeURL: URL(fileURLWithPath: "/tmp/hostpickerview-cb-\(UUID()).json"))
        var captured: Host?
        let view = HostPickerView(store: store) { host in
            captured = host
        }
        #expect(view.onSelect != nil)

        let probe = Host(
            id: UUID(),
            label: "probe",
            baseURL: URL(string: "https://probe.local")!,
            addedAt: Date(),
            lastUsedAt: nil
        )
        view.onSelect?(probe)
        #expect(captured?.id == probe.id)
    }
}
#endif
