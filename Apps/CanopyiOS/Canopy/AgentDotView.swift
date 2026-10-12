import CanopyWire
import SwiftUI

/// An agent's dot: the accent while working, yellow while waiting, green when done, and a green ring in the background.
struct AgentDotView: View {
    var dot: AgentDot?
    /// The small dot in a title or a connection line, without the halo.
    var small = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Group {
            switch dot {
            case .background:
                Circle()
                    .strokeBorder(Theme.ring, lineWidth: 1.5)
                    .frame(width: small ? 7 : 10, height: small ? 7 : 10)
                    .opacity(dimmed ? 0.35 : 1)
                    .animation(pulse(seconds: 3), value: dimmed)
            case .some(let dot):
                Circle()
                    .fill(color(dot))
                    .frame(width: small ? 6 : 8, height: small ? 6 : 8)
                    .background {
                        if !small {
                            Circle().fill(color(dot).opacity(0.22)).frame(width: 13, height: 13)
                        }
                    }
                    .opacity(dot == .working && dimmed ? 0.35 : 1)
                    .animation(dot == .working ? pulse(seconds: 1.6) : nil, value: dimmed)
            case nil:
                Color.clear.frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
        .onAppear { if !reduceMotion { dimmed = true } }
        .accessibilityLabel(label)
    }

    private func color(_ dot: AgentDot) -> Color {
        switch dot {
        case .working: Theme.accent
        case .waiting: Theme.yellow
        case .done, .background: Theme.green
        }
    }

    private func pulse(seconds: Double) -> Animation {
        .easeInOut(duration: seconds / 2).repeatForever(autoreverses: true)
    }

    private var label: String {
        switch dot {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .done: "Done"
        case .background: "Running in the background"
        case nil: "Idle"
        }
    }
}
