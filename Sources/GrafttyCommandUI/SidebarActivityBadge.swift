import SwiftUI

public struct SidebarActivityBadge: View {
    public enum Kind { case attention, working }
    public let count: Int
    public var kind: Kind

    public init(_ count: Int, kind: Kind = .attention) {
        self.count = count
        self.kind = kind
    }

    private var color: Color { kind == .working ? .green : .orange }
    private var label: String {
        kind == .working ? "\(count) \(count == 1 ? "agent" : "agents") working" : "\(count) needing attention"
    }

    @ViewBuilder
    public var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : String(count)).font(.system(size: 10, weight: .semibold)).fixedSize()
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(color)
                .help(label).accessibilityLabel(label)
        }
    }
}
