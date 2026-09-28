import AppKit
import CanopyCore
import SwiftUI

/// The git branch mark: a trunk with a commit at each end and a branch curving in from the right.
/// Drawn on a 24-point grid and scaled to the frame, so it stays crisp at any size.
struct BranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        var path = Path()
        path.move(to: CGPoint(x: 6, y: 3))
        path.addLine(to: CGPoint(x: 6, y: 15))
        path.addEllipse(in: CGRect(x: 15, y: 3, width: 6, height: 6))
        path.addEllipse(in: CGRect(x: 3, y: 15, width: 6, height: 6))
        path.move(to: CGPoint(x: 18, y: 9))
        path.addQuadCurve(to: CGPoint(x: 9, y: 18), control: CGPoint(x: 18, y: 18))
        return path.applying(transform)
    }
}

/// The pull request mark: a trunk with a commit on top, and a branch from a commit on the right back towards the
/// trunk, ending in an arrow. Same grid and stroke as the branch mark, so the two swap cleanly.
struct PullRequestGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        var path = Path()
        path.addEllipse(in: CGRect(x: 2, y: 3, width: 6, height: 6))
        path.move(to: CGPoint(x: 5, y: 9))
        path.addLine(to: CGPoint(x: 5, y: 21))
        path.addEllipse(in: CGRect(x: 16, y: 15, width: 6, height: 6))
        path.move(to: CGPoint(x: 19, y: 15))
        path.addLine(to: CGPoint(x: 19, y: 8))
        path.addQuadCurve(to: CGPoint(x: 17, y: 6), control: CGPoint(x: 19, y: 6))
        path.addLine(to: CGPoint(x: 12, y: 6))
        path.move(to: CGPoint(x: 15, y: 3))
        path.addLine(to: CGPoint(x: 12, y: 6))
        path.addLine(to: CGPoint(x: 15, y: 9))
        return path.applying(transform)
    }
}

/// A row's mark: its PR in the PR's state color, or a muted branch when it has none.
struct RowIcon: View {
    let row: Row
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Group {
            if let pr = row.pullRequest {
                PullRequestGlyph().stroke(pr.state.style(on: prominence), style: Self.stroke)
            } else {
                BranchGlyph().stroke(.secondary, style: Self.stroke)
            }
        }
        .frame(width: 14, height: 14)
    }

    private static let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
}

extension PRState {
    /// GitHub's own state colors, so a badge reads the way it does on github.com.
    var color: Color {
        switch self {
        case .open: .adaptive(light: 0x1A7F37, dark: 0x3FB950)
        case .draft: .adaptive(light: 0x59636E, dark: 0x9198A1)
        case .merged: .adaptive(light: 0x8250DF, dark: 0xAB7DF8)
        case .closed: .adaptive(light: 0xD1242F, dark: 0xF85149)
        }
    }

    /// On a selected row in a focused sidebar, state colors would clash with the accent color, so they turn white
    /// like the rest of the row.
    func style(on prominence: BackgroundProminence) -> AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color)
    }

    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

extension Color {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}
