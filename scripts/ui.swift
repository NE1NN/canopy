// Drives a running Canopy for UI checks, alongside window-shot.swift. Build it once, since `swift` takes seconds to
// start: swiftc -O -o build/ui scripts/ui.swift
//
//   ui activate <pid>                       bring the app to the front
//   ui frame <pid>                          print the main window's frame in screen points
//   ui key <pid> <keycode> [cmd] [shift] [opt] [ctrl]
//   ui type <pid> <text>
//   ui move <pid> <x> <y>                   points from the window's top-left, as in a window shot divided by 2
//   ui click <pid> <x> <y> [count]
//   ui rightclick <pid> <x> <y>             opens a context menu
//   ui drag <pid> <x1> <y1> <x2> <y2>
//   ui down <pid> <x> <y>                   press the button and keep it held, for a shot in the middle of a drag
//   ui drag-to <pid> <x> <y>                move there with the button held, from wherever the pointer is
//   ui up <pid> <x> <y>                     let go there
//   ui scroll <pid> <x> <y> <lines>         positive lines scroll up, into the scrollback
//
// Keys and text go to the app alone. Pointer events go through the system, so they refuse to run unless the app is
// frontmost. The process running this needs Accessibility permission in System Settings.
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: ui <command> <pid> [arguments], see the top of ui.swift\n".utf8))
    exit(2)
}

func number(_ index: Int) -> Double {
    guard index < args.count, let value = Double(args[index]) else {
        FileHandle.standardError.write(Data("\(args[0]) needs a number at position \(index)\n".utf8))
        exit(2)
    }
    return value
}

/// The largest layer-0 window the app owns: a frontmost app's menu bar strip is one too.
func windowFrame() -> CGRect {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let frames = windows.compactMap { window -> CGRect? in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
            (window[kCGWindowLayer as String] as? Int) == 0,
            let bounds = window[kCGWindowBounds as String]
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as! CFDictionary)
    }
    guard let frame = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
        FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
        exit(1)
    }
    return frame
}

func windowPoint(_ xIndex: Int) -> CGPoint {
    let frame = windowFrame()
    return CGPoint(x: frame.minX + number(xIndex), y: frame.minY + number(xIndex + 1))
}

func requireFrontmost() {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        FileHandle.standardError.write(Data("refusing to \(args[0]): the app is not frontmost\n".utf8))
        exit(1)
    }
}

func post(_ event: CGEvent) {
    event.postToPid(pid)
    usleep(15_000)
}

func mouse(_ type: CGEventType, at point: CGPoint, clickCount: Int64 = 1, button: CGMouseButton = .left) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
    event.setIntegerValueField(.mouseEventClickState, value: clickCount)
    event.post(tap: .cghidEventTap)
    usleep(20_000)
}

func modifiers(_ names: ArraySlice<String>) -> CGEventFlags {
    var flags: CGEventFlags = []
    for name in names {
        switch name {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
    return flags
}

switch args[0] {
case "activate":
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(300_000)
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? "front" : "not front")
case "frame":
    print(windowFrame())
case "key":
    let code = CGKeyCode(number(2))
    let flags = modifiers(args.dropFirst(3))
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        post(event)
    }
case "type":
    guard args.count > 2 else { exit(2) }
    for scalar in args[2].unicodeScalars {
        let units = Array(String(scalar).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(event)
        }
    }
case "move":
    requireFrontmost()
    mouse(.mouseMoved, at: windowPoint(2))
case "click":
    requireFrontmost()
    let point = windowPoint(2)
    let count = args.count > 4 ? Int(number(4)) : 1
    mouse(.mouseMoved, at: point)
    for click in 1...max(count, 1) {
        mouse(.leftMouseDown, at: point, clickCount: Int64(click))
        mouse(.leftMouseUp, at: point, clickCount: Int64(click))
    }
case "rightclick":
    requireFrontmost()
    let point = windowPoint(2)
    mouse(.mouseMoved, at: point)
    mouse(.rightMouseDown, at: point, button: .right)
    mouse(.rightMouseUp, at: point, button: .right)
case "down":
    requireFrontmost()
    let point = windowPoint(2)
    mouse(.mouseMoved, at: point)
    mouse(.leftMouseDown, at: point)
case "drag-to":
    requireFrontmost()
    let from = CGEvent(source: nil)?.location ?? windowPoint(2)
    let to = windowPoint(2)
    for step in 1...20 {
        let t = Double(step) / 20
        mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    }
case "up":
    requireFrontmost()
    let point = windowPoint(2)
    mouse(.leftMouseDragged, at: point)
    mouse(.leftMouseUp, at: point)
case "drag":
    requireFrontmost()
    let from = windowPoint(2)
    let to = windowPoint(4)
    mouse(.mouseMoved, at: from)
    mouse(.leftMouseDown, at: from)
    for step in 1...30 {
        let t = Double(step) / 30
        mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    }
    usleep(200_000)
    mouse(.leftMouseUp, at: to)
case "scroll":
    requireFrontmost()
    mouse(.mouseMoved, at: windowPoint(2))
    let lines = Int32(number(4))
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
    event.post(tap: .cghidEventTap)
default:
    FileHandle.standardError.write(Data("unknown command \(args[0]), see the top of ui.swift\n".utf8))
    exit(2)
}
