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

struct BranchIcon: View {
    var color: Color = .green

    var body: some View {
        BranchGlyph()
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 14, height: 14)
    }
}
