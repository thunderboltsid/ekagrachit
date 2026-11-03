// ekagrachit-probe: test driver for desktop-level E2E tests (macOS only, not shipped).
//
//   ekagrachit-probe env                    -> {"axTrusted":…, "screens":[…], "frontmost":{…}}
//   ekagrachit-probe windows                -> on-screen windows, front to back (global top-left coords)
//   ekagrachit-probe click X Y              -> synthetic left click at global point
//   ekagrachit-probe key KEYCODE [cmd,shift,ctrl,opt]
//   ekagrachit-probe activate BUNDLE_ID     -> activate another app (like Cmd+Tab)
//   ekagrachit-probe frontmost              -> {"pid":…, "bundle":…}
import AppKit
import ApplicationServices
import Foundation

func emit(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func frontmost() -> [String: Any] {
    let app = NSWorkspace.shared.frontmostApplication
    return ["pid": Int(app?.processIdentifier ?? 0), "bundle": app?.bundleIdentifier ?? "", "name": app?.localizedName ?? ""]
}

func windows() -> [[String: Any]] {
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return raw.compactMap { d in
        guard let b = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return [
            "number": (d[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
            "pid": (d[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0,
            "owner": d[kCGWindowOwnerName as String] as? String ?? "",
            "layer": (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            "alpha": (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            "x": r.origin.x, "y": r.origin.y, "w": r.width, "h": r.height,
        ]
    }
}

func screens() -> [[String: Any]] {
    // Global top-left coordinates (same space as CGWindowList).
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    return NSScreen.screens.map { s in
        let f = s.frame, v = s.visibleFrame
        return ["x": f.minX, "y": primaryH - f.maxY, "w": f.width, "h": f.height,
                "visible": ["x": v.minX, "y": primaryH - v.maxY, "w": v.width, "h": v.height]]
    }
}

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(30_000) }

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "env":
    emit(["axTrusted": AXIsProcessTrusted(), "screens": screens(), "frontmost": frontmost()])
case "windows":
    emit(windows())
case "brightness":
    // brightness FILE X Y W H  (points on the primary screen) -> mean luminance 0…1
    let a = Array(args)
    guard let data = FileManager.default.contents(atPath: a[1]), let rep = NSBitmapImageRep(data: data),
          let primary = NSScreen.screens.first else { emit(["error": "unreadable"]); exit(1) }
    let scale = Double(rep.pixelsWide) / primary.frame.width
    let x0 = Int(Double(a[2])! * scale), y0 = Int(Double(a[3])! * scale)
    let w = Int(Double(a[4])! * scale), h = Int(Double(a[5])! * scale)
    var sum = 0.0, n = 0.0
    for y in stride(from: max(0, y0), to: min(rep.pixelsHigh, y0 + h), by: 3) {
        for x in stride(from: max(0, x0), to: min(rep.pixelsWide, x0 + w), by: 3) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3
                n += 1
            }
        }
    }
    emit(["brightness": n > 0 ? sum / n : -1, "samples": n])
case "frontmost":
    emit(frontmost())
case "statusitem":
    // statusitem PID -> frame of that app's menu-bar extra (via Accessibility)
    let pid = pid_t(Int(Array(args)[1])!)
    let app = AXUIElementCreateApplication(pid)
    var bar: CFTypeRef?
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
          AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
          let item = (kids as? [AXUIElement])?.first else { emit(["error": "no status item"]); exit(0) }
    var pos: CFTypeRef?
    var size: CFTypeRef?
    AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pos)
    AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size)
    var p = CGPoint.zero
    var z = CGSize.zero
    if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
    if let size { AXValueGetValue(size as! AXValue, .cgSize, &z) }
    emit(["x": p.x, "y": p.y, "w": z.width, "h": z.height])
case "click":
    let a = Array(args)
    let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
    emit(["ok": true])
case "mousedown", "mouseup":
    let a = Array(args)
    let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
    post(CGEvent(mouseEventSource: nil, mouseType: a[0] == "mousedown" ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
    emit(["ok": true])
case "keydown", "keyup":
    let a = Array(args)
    post(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(Int(a[1])!), keyDown: a[0] == "keydown"))
    emit(["ok": true])
case "key":
    let a = Array(args)
    let code = CGKeyCode(Int(a[1])!)
    var flags: CGEventFlags = []
    for m in (a.count > 2 ? a[2] : "").split(separator: ",") {
        switch m {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        case "opt": flags.insert(.maskAlternate)
        default: break
        }
    }
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
    down?.flags = flags
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    up?.flags = flags
    post(down)
    post(up)
    emit(["ok": true])
case "activate":
    let id = Array(args)[1]
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
        emit(["ok": app.activate(options: [.activateIgnoringOtherApps])])
    } else {
        emit(["ok": false, "error": "not running"])
    }
default:
    FileHandle.standardError.write(Data("usage: ekagrachit-probe env|windows|frontmost|click X Y|key CODE [mods]|activate BUNDLE\n".utf8))
    exit(2)
}
