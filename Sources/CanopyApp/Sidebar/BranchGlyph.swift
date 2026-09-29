import AppKit
import CanopyCore
import SwiftUI

/// A branch, pull request, or trunk mark, drawn on a 24-unit grid meant for a 12-point frame, so a unit is half a
/// point. Each mark is 10 points tall, about the height of the row text's ascenders, and the branch and pull request
/// marks share a 9-point width. The vertical lines sit on odd units, so in a frame placed on whole points, the 1-point
/// stroke's edges land on whole pixels at 1x and 2x.
protocol MarkShape: Shape {
    func path(on grid: inout Path)
}

extension MarkShape {
    func path(in rect: CGRect) -> Path {
        var grid = Path()
        path(on: &grid)
        let scale = min(rect.width, rect.height) / 24
        return grid.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }

    /// The mark at the one size and weight it is drawn for.
    func mark(_ style: some ShapeStyle) -> some View {
        stroke(style, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            .frame(width: 12, height: 12)
    }
}

/// The git branch mark: a trunk ending in a commit, and a branch curving in from a commit at the top right.
struct BranchGlyph: MarkShape {
    func path(on grid: inout Path) {
        grid.move(to: CGPoint(x: 7, y: 3))
        grid.addLine(to: CGPoint(x: 7, y: 15))
        grid.addEllipse(in: CGRect(x: 4, y: 15, width: 6, height: 6))
        grid.addEllipse(in: CGRect(x: 14, y: 3, width: 6, height: 6))
        grid.move(to: CGPoint(x: 17, y: 9))
        grid.addQuadCurve(to: CGPoint(x: 10, y: 18), control: CGPoint(x: 17, y: 18))
    }
}

/// The pull request mark: a trunk with a commit on top, and a branch from a commit at the bottom right back towards
/// the trunk, ending in an arrow. It fills the same box as the branch mark, so the two swap cleanly.
struct PullRequestGlyph: MarkShape {
    func path(on grid: inout Path) {
        grid.addEllipse(in: CGRect(x: 4, y: 3, width: 6, height: 6))
        grid.move(to: CGPoint(x: 7, y: 9))
        grid.addLine(to: CGPoint(x: 7, y: 21))
        grid.addEllipse(in: CGRect(x: 14, y: 15, width: 6, height: 6))
        grid.move(to: CGPoint(x: 17, y: 15))
        grid.addLine(to: CGPoint(x: 17, y: 8.5))
        grid.addQuadCurve(to: CGPoint(x: 14.5, y: 6), control: CGPoint(x: 17, y: 6))
        grid.addLine(to: CGPoint(x: 13, y: 6))
        grid.move(to: CGPoint(x: 15, y: 4))
        grid.addLine(to: CGPoint(x: 13, y: 6))
        grid.addLine(to: CGPoint(x: 15, y: 8))
    }
}

/// The main checkout's mark: the trunk, a line through a commit.
struct TrunkGlyph: MarkShape {
    func path(on grid: inout Path) {
        grid.move(to: CGPoint(x: 11, y: 3))
        grid.addLine(to: CGPoint(x: 11, y: 8.5))
        grid.addEllipse(in: CGRect(x: 7.5, y: 8.5, width: 7, height: 7))
        grid.move(to: CGPoint(x: 11, y: 15.5))
        grid.addLine(to: CGPoint(x: 11, y: 21))
    }
}

/// A row's mark: its PR in the PR's state color, the trunk for the main checkout, or a muted branch.
struct RowMark: View {
    let row: Row

    var body: some View {
        if let pr = row.pullRequest {
            PullRequestGlyph().mark(pr.state.color)
        } else if row.rowClass == .main {
            TrunkGlyph().mark(row.isMissing ? .tertiary : .secondary)
        } else {
            BranchGlyph().mark(row.isMissing ? .tertiary : .secondary)
        }
    }
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

    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}
