// Captures the main window of a process, even when it is behind other apps or not yet shown.
//
//   swift scripts/window-shot.swift <pid> <out.png>         the main window alone
//   swift scripts/window-shot.swift <pid> <out.png> --all   the main window with the app's own menus and popovers,
//                                                          drawn over it, and nothing of any other app
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let pid = Int32(CommandLine.arguments[1])!
// screencapture runs as part of the app hosting this terminal, which needs Screen Recording. Without it the capture fails
// with only "could not create image from window".
guard CGPreflightScreenCaptureAccess() else {
    FileHandle.standardError.write(
        Data(
            """
            Screen Recording is off for the app running this terminal. Turn it on in System Settings > Privacy & Security \
            > Screen Recording. macOS then offers to quit and reopen that app, which closes its terminals.

            """.utf8))
    exit(1)
}
let output = CommandLine.arguments[2]
let withMenus = CommandLine.arguments.dropFirst(3).contains("--all")

func bounds(_ window: [String: Any]) -> CGRect {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
}

func capture(_ number: Int, to path: String) -> Int32 {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(number), path]
    try? capture.run()
    capture.waitUntilExit()
    return capture.terminationStatus
}

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }

// A frontmost app's menu bar strip is also a layer-0 window it owns, so take the largest.
guard
    let main = owned.filter({ ($0[kCGWindowLayer as String] as? Int) == 0 })
        .max(by: { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height }),
    let mainNumber = main[kCGWindowNumber as String] as? Int
else {
    FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
    exit(1)
}
guard withMenus else { exit(capture(mainNumber, to: output)) }

// Menus and popovers are windows of their own that `screencapture -l` cannot take. ScreenCaptureKit draws the app's
// on-screen windows alone, over the main window's rectangle, so no other app's window can appear.
let frame = bounds(main)
let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
else {
    FileHandle.standardError.write(Data("no display shows the window\n".utf8))
    exit(1)
}
let own = content.windows.filter { $0.owningApplication?.processID == pid }
let filter = SCContentFilter(display: display, including: own)
let configuration = SCStreamConfiguration()
configuration.sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
configuration.width = Int(frame.width * CGFloat(filter.pointPixelScale))
configuration.height = Int(frame.height * CGFloat(filter.pointPixelScale))
configuration.showsCursor = false
let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
guard
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
