import SwiftUI

/// The small status dot shared by pinned tiles and gallery tiles (LAYOUT-2.225, LAYOUT-2.250).
public struct AgentStatusDot: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let dot: AgentTileDot?
    let size: CGFloat

    public init(dot: AgentTileDot?, size: CGFloat = 7) { self.dot = dot; self.size = size }

    /// The working colour: a quiet blue that reads as in progress, not as an alarm;
    /// deeper in light mode so it still reads on a pale background.
    public static func working(isDark: Bool) -> Color {
        isDark ? Color(.sRGB, red: 0.48, green: 0.66, blue: 1, opacity: 1) : Color(.sRGB, red: 0, green: 0.45, blue: 0.95, opacity: 1)
    }
    /// The asking colour: plain orange in both modes.
    public static let asking = Color(.sRGB, red: 1, green: 0.58, blue: 0.05, opacity: 1)

    public var body: some View {
        switch dot {
        case .asking?:
            Circle().fill(Self.asking).frame(width: size, height: size)
        case .working?:
            AgentStatusPulse(reduceMotion: reduceMotion) { opacity in
                Circle().fill(Self.working(isDark: colorScheme == .dark)).frame(width: size, height: size).opacity(opacity)
            }
        case nil:
            EmptyView()
        }
    }
}

/// A slow pulse for working agents. It needs no more than 30 frames a second,
/// and agents work for hours.
public struct AgentStatusPulse<Content: View>: View {
    let reduceMotion: Bool
    let content: (Double) -> Content

    public init(reduceMotion: Bool, @ViewBuilder content: @escaping (Double) -> Content) {
        self.reduceMotion = reduceMotion; self.content = content
    }

    public var body: some View {
        if reduceMotion {
            content(1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                content(0.35 + 0.65 * abs(cos(phase * .pi)))
            }
        }
    }
}
