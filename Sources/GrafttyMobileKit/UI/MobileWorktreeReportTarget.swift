#if canImport(UIKit)
import SwiftUI
import GrafttyCommandUI

struct MobileWorktreeReportContent: View {
    let context: SidebarWorktreeContext
    let onOpen: () async -> Bool
    let onDismiss: () -> Void
    let onClose: () -> Void

    var body: some View {
        SidebarWorktreeReport(context: context, onOpen: onOpen, onDismiss: onDismiss, onClose: onClose)
            .frame(idealWidth: 380, idealHeight: 440)
            .frame(maxHeight: 600)
    }
}

/// An exclusive gesture keeps a recognized hold from also opening a terminal.
struct MobileWorktreeReportTarget<Content: View>: View {
    static var holdDuration: Double { 0.5 }
    @Environment(\.editMode) private var editMode
    @State private var hoverTask: Task<Void, Never>?
    let onOpen: () -> Void
    let onReport: () -> Void
    @ViewBuilder let content: () -> Content

    func activate(_ value: ExclusiveGesture<LongPressGesture, TapGesture>.Value) {
        hoverTask?.cancel()
        hoverTask = nil
        switch value {
        case .first(true): onReport()
        case .first(false): break
        case .second: onOpen()
        }
    }

    var body: some View {
        content()
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 10)
                    .onEnded { activate(.first($0)) }
                    .exclusively(before: TapGesture().onEnded { activate(.second($0)) }),
                including: editMode?.wrappedValue.isEditing == true ? .none : .all
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: "Show report") { onReport() }
            .onHover { hovering in
                hoverTask?.cancel()
                guard hovering, editMode?.wrappedValue.isEditing != true else { return }
                hoverTask = Task {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard !Task.isCancelled else { return }
                    onReport()
                }
            }
            .onDisappear { hoverTask?.cancel() }
    }
}
#endif
