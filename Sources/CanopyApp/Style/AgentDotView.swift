import AppKit
import CanopyCore
import SwiftUI

/// What a pane's agent is doing: the accent color pulsing while it works, yellow while it waits for the author, green
/// once it is done, until the author sees it, and a slowly pulsing green ring while its turn is over but background
/// work it started still runs.
struct AgentDotView: View {
    let dot: AgentDot
    var size = 6.0
    /// What a background dot waits on, which its tooltip names.
    var tasks: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch dot {
            case .working where !reduceMotion:
                PulsingDot(look: .working, size: size, help: dot.help(tasks: tasks))
            case .background where !reduceMotion:
                PulsingDot(look: .background, size: size, help: dot.help(tasks: tasks))
            case .background:
                Circle()
                    .strokeBorder(Color(nsColor: Style.agentBackgroundRing), lineWidth: Self.ringLine)
                    .frame(width: Self.ringWidth(size), height: Self.ringWidth(size))
            default:
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .background(Circle().fill(color.opacity(0.22)).padding(-Self.halo))
            }
        }
        .frame(width: size, height: size)
        .help(dot.help(tasks: tasks))
        .accessibilityElement()
        .accessibilityLabel(dot.help(tasks: tasks))
    }

    /// How far the soft ring reaches past the dot.
    static let halo = 2.5
    static let ringLine = 1.5

    /// The background ring's outer width, a little wider than the dot so its empty middle reads at a glance.
    static func ringWidth(_ size: Double) -> Double {
        size + 3
    }

    private var color: Color {
        switch dot {
        case .working: .accentColor
        case .waiting: Style.agentWaiting
        case .done, .background: Style.agentDone
        }
    }
}

extension AgentDot {
    /// The short form, for the label of a row or header that holds the dot.
    func label(tasks: [String]) -> String {
        switch self {
        case .working: "Agent working"
        case .waiting: "Agent waiting for you"
        case .done: "Agent done"
        case .background: BackgroundWork.label(tasks)
        }
    }

    /// The short form inside a longer label: "agent waiting on background work: npm test", keeping the work's case.
    func inlineLabel(tasks: [String]) -> String {
        let text = label(tasks: tasks)
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// The tooltip, which for background names the work it waits on.
    func help(tasks: [String]) -> String {
        self == .background ? BackgroundWork.summary(tasks) : label(tasks: tasks)
    }

    /// A row's or header's own tooltip with the dot's under it. A container's tooltip covers its children's, so the
    /// dot's tooltip shows only where nothing around it has one.
    static func help(_ base: String, dot: AgentDot?, tasks: [String]) -> String {
        guard let dot else { return base }
        return base + "\n" + dot.help(tasks: tasks)
    }
}

/// The working dot and the background ring. Core Animation runs the pulse outside the app, where a SwiftUI animation
/// would redraw the window every frame for as long as an agent works.
private struct PulsingDot: NSViewRepresentable {
    let look: PulsingDotView.Look
    let size: Double
    /// AppKit shows the tooltip of the view under the pointer, so the hosted view carries its own.
    let help: String

    func makeNSView(context: Context) -> PulsingDotView {
        let view = PulsingDotView(look: look, size: size)
        view.toolTip = help
        return view
    }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.toolTip = help
    }
}

private final class PulsingDotView: NSView {
    enum Look {
        /// The accent color, filled with a halo, pulsing about every 1.6 seconds.
        case working
        /// A green ring, pulsing about every 3 seconds, slower than working since nothing happens until the work ends.
        case background
    }

    private let look: Look
    private let dot = CALayer()
    private let ring = CALayer()
    private let outline = CAShapeLayer()
    private let size: Double

    init(look: Look, size: Double) {
        self.look = look
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.masksToBounds = false
        switch look {
        case .working:
            let halo = AgentDotView.halo
            ring.frame = CGRect(x: -halo, y: -halo, width: size + 2 * halo, height: size + 2 * halo)
            ring.cornerRadius = ring.frame.width / 2
            dot.frame = CGRect(x: 0, y: 0, width: size, height: size)
            dot.cornerRadius = size / 2
            layer?.addSublayer(ring)
            layer?.addSublayer(dot)
        case .background:
            let width = AgentDotView.ringWidth(size)
            let line = AgentDotView.ringLine
            let inset = (size - width) / 2 + line / 2
            outline.path = CGPath(
                ellipseIn: CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset), transform: nil)
            outline.lineWidth = line
            outline.fillColor = nil
            layer?.addSublayer(outline)
        }
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

    /// Resolves the colors for the current appearance, which a CGColor cannot follow by itself.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = NSColor.controlAccentColor.cgColor
            ring.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            outline.strokeColor = Style.agentBackgroundRing.cgColor
        }
    }

    /// Core Animation drops a layer's animations when its view leaves the window, so each arrival starts the pulse.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = look == .working ? 0.35 : 0.6
        pulse.duration = look == .working ? 0.8 : 1.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}
