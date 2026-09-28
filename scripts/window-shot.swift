// Captures the main window of a process, even when it is behind other apps or not yet shown.
// Usage: swift scripts/window-shot.swift <pid> <out.png>
import CoreGraphics
import Foundation

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
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []

// A frontmost app's menu bar strip is also a layer-0 window it owns, so take the largest.
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}

guard
    let window =
        windows
        .filter({
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        })
        .max(by: { area($0) < area($1) }),
    let number = window[kCGWindowNumber as String] as? Int
else {
    FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
    exit(1)
}
let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", "-o", "-l", String(number), output]
try capture.run()
capture.waitUntilExit()
exit(capture.terminationStatus)
