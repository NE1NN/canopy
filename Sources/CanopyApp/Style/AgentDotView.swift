import AppKit
import CanopyCore
import SwiftUI

/// What a pane's agent is doing: the accent color pulsing while it works, yellow while it waits for the author, and
/// green once it is done, until the author sees it.
struct AgentDotView: View {
    let dot: AgentDot
    var size = 6.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if dot == .working && !reduceMotion {
                PulsingDot(size: size)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .background(Circle().fill(color.opacity(0.22)).padding(-Self.halo))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(dot.label)
    }

    /// How far the soft ring reaches past the dot.
    static let halo = 2.5

    private var color: Color {
        switch dot {
        case .working: .accentColor
        case .waiting: Style.agentWaiting
        case .done: Style.agentDone
        }
    }
}

extension AgentDot {
    var label: String {
        switch self {
        case .working: "Agent working"
        case .waiting: "Agent waiting for you"
        case .done: "Agent done"
        }
    }
}

/// The working dot. Core Animation runs the pulse outside the app, where a SwiftUI animation would redraw the
/// window every frame for as long as an agent works.
private struct PulsingDot: NSViewRepresentable {
    let size: Double

    func makeNSView(context: Context) -> PulsingDotView {
        PulsingDotView(size: size)
    }

    func updateNSView(_ view: PulsingDotView, context: Context) {}
}

private final class PulsingDotView: NSView {
    private let dot = CALayer()
    private let ring = CALayer()
    private let size: Double

    init(size: Double) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        let halo = AgentDotView.halo
        ring.frame = CGRect(x: -halo, y: -halo, width: size + 2 * halo, height: size + 2 * halo)
        ring.cornerRadius = ring.frame.width / 2
        dot.frame = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        layer?.masksToBounds = false
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
        // A new accent color in System Settings.
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
    }

    @objc private func systemColorsChanged() {
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    override var wantsUpdateLayer: Bool { true }

    /// Resolves the accent color for the current appearance, which a CGColor cannot follow by itself.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = NSColor.controlAccentColor.cgColor
            ring.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        }
    }

    /// Core Animation drops a layer's animations when its view leaves the window, so each arrival starts the pulse.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}
