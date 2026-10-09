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

/// A sibling of the terminal tap target so preview never also opens a pane.
struct MobileWorktreeReportButton: View {
    let worktreeName: String
    let onReport: () -> Void

    func activate() { onReport() }

    var body: some View {
        Button(action: activate) {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show report for \(worktreeName)")
    }
}

/// An exclusive gesture keeps a recognized hold from also opening a terminal.
struct MobileWorktreeReportTarget<Content: View>: View {
    static var holdDuration: Double { 0.5 }
    @Environment(\.editMode) private var editMode
    let onOpen: () -> Void
    let onReport: () -> Void
    @ViewBuilder let content: () -> Content

    func activate(_ value: ExclusiveGesture<LongPressGesture, TapGesture>.Value) {
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
    }
}
#endif
