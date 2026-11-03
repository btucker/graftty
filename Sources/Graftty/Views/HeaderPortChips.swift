import AppKit
import SwiftUI
import GrafttyKit
import GrafttyProtocol

/// The ports the selected worktree's panes listen on, one chip per port.
struct HeaderPortChips: Equatable {
    struct Entry: Equatable {
        let binding: PortBinding
        /// The pane that owns it, needed to forward a remote port.
        let session: String?
    }

    static let visibleLimit = 2
    let visible: [Entry]
    let overflow: [Entry]

    init(entries: [Entry]) {
        var seen: Set<UInt16> = []
        let unique = entries.sorted { $0.binding.port < $1.binding.port }.filter { seen.insert($0.binding.port).inserted }
        visible = Array(unique.prefix(Self.visibleLimit))
        overflow = Array(unique.dropFirst(Self.visibleLimit))
    }
}

struct HeaderPortChipsView: View {
    let chips: HeaderPortChips
    let theme: GhosttyTheme
    /// Nil opens a local port directly, as `PortChip` does by default.
    let onOpen: ((HeaderPortChips.Entry) -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(chips.visible, id: \.binding.port) { entry in
                PortChip(binding: entry.binding, theme: theme, onOpen: onOpen.map { open in { open(entry) } })
            }
            if !chips.overflow.isEmpty {
                Menu("+\(chips.overflow.count)") {
                    ForEach(chips.overflow, id: \.binding.port) { entry in
                        Button(PortChip.label(for: entry.binding)) {
                            if let onOpen { onOpen(entry) }
                            else if let url = PortChip.url(for: entry.binding) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 10.5, weight: .medium))
            }
        }
        .fixedSize()
    }
}
