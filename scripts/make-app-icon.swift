// Draws the iPhone app's icon: the canopy glyph, white on Canopy's green, with no alpha channel.
// Usage: swift scripts/make-app-icon.swift <out.png>
import AppKit

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { exit(1) }
// Top-left origin, as the mockup's path is drawn.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

let colors = [
    CGColor(srgbRed: 0x2E / 255, green: 0x7D / 255, blue: 0x4F / 255, alpha: 1),
    CGColor(srgbRed: 0x15 / 255, green: 0x50 / 255, blue: 0x2F / 255, alpha: 1),
]
let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])

// The glyph spans 14 units of an 18 unit grid, centered, at 56% of the icon.
let scale = CGFloat(size) * 0.56 / 14
let origin = CGPoint(x: CGFloat(size) / 2 - 9 * scale, y: CGFloat(size) / 2 - 9 * scale)
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
let path = CGMutablePath()
path.move(to: point(9, 2))
path.addCurve(to: point(15, 7.6), control1: point(12.5, 2), control2: point(15, 4.6))
path.addCurve(to: point(11.6, 12.1), control1: point(15, 9.8), control2: point(13.6, 11.5))
path.addLine(to: point(6.4, 12.1))
path.addCurve(to: point(3, 7.6), control1: point(4.4, 11.5), control2: point(3, 9.8))
path.addCurve(to: point(9, 2), control1: point(3, 4.6), control2: point(5.5, 2))
path.closeSubpath()
path.move(to: point(9, 12.1))
path.addLine(to: point(9, 16))
context.addPath(path)
context.setStrokeColor(CGColor(gray: 1, alpha: 1))
context.setLineWidth(1.6 * scale)
context.setLineCap(.round)
context.setLineJoin(.round)
context.strokePath()

guard let image = context.makeImage(),
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { exit(1) }
try png.write(to: out)
