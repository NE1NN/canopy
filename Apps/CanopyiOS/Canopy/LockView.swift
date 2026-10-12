import CanopyPhone
import SwiftUI

/// Covers the app while it is locked, or while it is away so the app switcher shows nothing.
struct LockView: View {
    @Environment(PhoneApp.self) private var app
    var locked: Bool

    var body: some View {
        VStack(spacing: 18) {
            AppGlyph(size: 64)
            if locked {
                Text("Canopy is locked")
                    .font(.title3.weight(.semibold))
                Button("Unlock") { Task { await app.lock.unlock() } }
                    .buttonStyle(ChipStyle(kind: .solid))
                    .accessibilityIdentifier("unlock")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .background(Theme.background)
        .task(id: locked) {
            if locked { await app.lock.unlock() }
        }
    }
}

/// The app's icon, drawn: a canopy over its trunk, white on green.
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        CanopyShape()
            .stroke(.white, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, lineJoin: .round))
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color(light: 0x2E7D4F, dark: 0x2E7D4F), Color(light: 0x15502F, dark: 0x15502F)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: size * 0.225, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// The mockup's glyph, on an 18 point grid: the crown, then the trunk.
struct CanopyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 14
        let origin = CGPoint(x: rect.midX - 9 * scale, y: rect.midY - 9 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        path.move(to: point(9, 2))
        path.addCurve(to: point(15, 7.6), control1: point(12.5, 2), control2: point(15, 4.6))
        path.addCurve(to: point(11.6, 12.1), control1: point(15, 9.8), control2: point(13.6, 11.5))
        path.addLine(to: point(6.4, 12.1))
        path.addCurve(to: point(3, 7.6), control1: point(4.4, 11.5), control2: point(3, 9.8))
        path.addCurve(to: point(9, 2), control1: point(3, 4.6), control2: point(5.5, 2))
        path.closeSubpath()
        path.move(to: point(9, 12.1))
        path.addLine(to: point(9, 16))
        return path
    }
}
