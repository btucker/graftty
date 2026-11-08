import AppKit
import SwiftUI
import GrafttyKit
import GrafttyProtocol
import Testing
@testable import Graftty

@MainActor
struct PRNumberFormattingTests {
    @Test("@spec PR-8.29: When displaying a PR/MR number in the breadcrumb or branch picker, the application shall use ungrouped decimal digits regardless of locale.", arguments: ["en_US", "de_DE", "fr_FR"])
    func numbersRenderWithoutGrouping(locale: String) throws {
        for number in [999, 1_000, 1_234_567] {
            for state: PRInfo.State in [.open, .merged, .closed] {
                let info = PRInfo(number: number, title: "Fix formatting",
                                  url: URL(string: "https://github.com/example/repo/pull/\(number)")!,
                                  state: state, checks: .success, fetchedAt: Date(timeIntervalSince1970: 0))
                for compact in [false, true] {
                    let button = PRButton(info: info, theme: .fallback, onRefresh: {}, compact: compact)
                    let suffix = compact ? "" : state == .merged ? " ✓ merged" : state == .closed ? " ✕ closed" : ""
                    let label = try renderedText(button.referenceLabel, locale: locale)
                    #expect(label == "#\(number)\(suffix)")
                }
            }
            let summary = BranchPickerEntry.PRSummary(number: number, title: "Fix formatting")
            let label = try renderedText(BranchPicker.prLabel(for: summary), locale: locale)
            #expect(label == "#\(number) · Fix formatting")
        }
    }

    @Test("Breadcrumb accessibility labels and tooltips keep identifiers ungrouped", arguments: ["en_US", "de_DE", "fr_FR"])
    func metadataNumbersRenderWithoutGrouping(locale: String) throws {
        let info = PRInfo(number: 5_000, title: "Fix formatting",
                          url: URL(string: "https://github.com/example/repo/pull/5000")!,
                          state: .open, checks: .success, fetchedAt: Date(timeIntervalSince1970: 0))
        let button = PRButton(info: info, theme: .fallback, onRefresh: {})
        let label = try renderedText(button, locale: locale)
        #expect(label == "Pull request 5000, CI passing, Fix formatting. Click to open in browser.")
        let tooltip = try renderedText(button, locale: locale, attribute: "accessibilityHelp")
        #expect(tooltip == "#5000 · Fix formatting\nCI passing")
    }

    // Resolve the production Text through SwiftUI so numeric interpolation's
    // locale formatting is exercised, rather than testing String interpolation.
    private func renderedText<V: View>(_ text: V, locale: String, attribute: String = "accessibilityLabel") throws -> String {
        let host = NSHostingView(rootView: text
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: .init(origin: .init(x: -10000, y: -10000), size: host.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        return try #require(accessibilityText(host, attribute: attribute))
    }

    private func accessibilityText(_ element: NSObject, attribute: String) -> String? {
        func value<T>(_ selector: String) -> T? {
            guard element.responds(to: NSSelectorFromString(selector)) else { return nil }
            return element.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? T
        }
        let label: String? = value(attribute)
        let content: String? = attribute == "accessibilityLabel" ? value("accessibilityValue") : nil
        if let text = [label, content].compactMap({ $0 }).first(where: { !$0.isEmpty }) { return text }
        let children: [NSObject] = value("accessibilityChildren") ?? []
        for child in children {
            if let text = accessibilityText(child, attribute: attribute) { return text }
        }
        return nil
    }
}
