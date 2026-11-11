// iphone-mirror: drive the macOS "iPhone Mirroring" app from the command line.
//
// One dependency-free Swift file (AppKit, CoreGraphics, ApplicationServices, ImageIO). The `iphone-mirror`
// wrapper next to this file compiles it with `swiftc` on first use. To compile it yourself:
//
//     swiftc -O iphone-mirror.swift -o iphone-mirror
//
// COORDINATES. Every x/y you pass is in SCREENSHOT PIXELS of an image made by `iphone-mirror shot`.
// By default `shot` saves the image at window-point size (1 px = 1 pt, even on Retina), so you can read a
// coordinate off the image and pass it straight to `tap`. If you capture with `shot --native` on a Retina
// display, pass `--ref <that.png>` (or `--scale 2`) to tap/scroll/swipe so pixels are mapped back to points.
//
// WHY TAPS ARE DONE THIS WAY. iPhone Mirroring tracks the phone-side pointer from mouse-MOVE events, and a
// click lands wherever that pointer currently is. A bare synthetic mouseDown/mouseUp does nothing, and
// warping the cursor before clicking makes the click land at the PREVIOUS pointer position. What works:
// glide to the target with ~25 small mouseMoved events (~12 ms apart), wait ~500 ms for the phone pointer
// to catch up, then mouseDown, hold ~120 ms, mouseUp (clickState = 1), all posted on the HID event tap.
//
// PERMISSIONS. The app that runs this shell (Terminal, iTerm, Warp, Ghostty, an IDE...) needs
// Accessibility (events, menus) and Screen & System Audio Recording (screenshots). Screen Recording only
// takes effect after that app is fully quit (cmd+Q) and reopened. `iphone-mirror doctor` checks all of it.

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

let toolVersion = "1.0.0"

let usage = """
iphone-mirror \(toolVersion): control the macOS iPhone Mirroring app.

Coordinates are screenshot pixels of `iphone-mirror shot` images (1 px = 1 window point by default).

Setup and state
  doctor [--prompt]               Check permissions, host app, window and scale. --prompt asks macOS to
                                  show the permission dialogs.
  info                            Print window info as JSON (position, size, scale, frontmost...).

Look
  shot <out.png> [--native]       Screenshot the phone window (no shadow). Default size = window points;
                                  --native keeps Retina pixels (then pass --ref/--scale when tapping).
  wait-settle [--timeout ms] [--interval ms] [--region x1 y1 x2 y2]
                                  Wait until the screen stops changing (exit 0) or time out (exit 4).
  color <img.png> <x> <y> [<x> <y> ...]
                                  Print the pixel colour(s) as #RRGGBB.
  has-color <img.png> <x1> <y1> <x2> <y2> <#RRGGBB> [--tol 40]
                                  Exit 0 if any pixel in the box is within --tol of the colour.
  join <out.png> <a.png> <b.png> ... [--crop-top px] [--crop-bottom px] [--trim-bars] [--gap px]
                                  [--resize f]
                                  Put screenshots side by side in one image (saves tokens).

Act (each one brings iPhone Mirroring to the front first; --no-activate skips that)
  tap <x> <y> [--hold ms] [--wait ms] [--steps n]
                                  Glide the pointer to (x, y), wait, click. --hold 800 = long press
                                  (experimental).
  scroll <dy> [--at x y] [--times n] [--interval ms] [--settle ms]
                                  Scroll wheel in pixels per event (default 8 events). Negative dy =
                                  move down the page. Waits --settle (default 2500 ms) for momentum.
  swipe <x1> <y1> <x2> <y2> [--duration ms]
                                  EXPERIMENTAL press-drag-release gesture.
  menu <home|app-switcher|spotlight|paste|"Exact Title">
                                  Press a menu item of iPhone Mirroring (localized names handled).
  menu --list                     List every menu item with its shortcut.

Common options for tap/scroll/swipe/menu
  --ref <img.png>                 Scale = image width / window width (use with `shot --native`).
  --scale <s>                     Explicit pixels-per-point of your coordinates (default 1).
  --shot <out.png> [--delay ms]   After the action, wait --delay (default 1000; scroll: 0) and screenshot.
  --no-activate                   Do not bring iPhone Mirroring to the front.
  --force                         Act even if another window covers the target point.
  --dry-run                       Print the global screen point(s) and exit without sending events.

Exit codes: 0 ok, 1 usage/other, 2 app/window missing, 3 permission/capture failure, 4 timeout/not found.
"""

// MARK: - Small helpers

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func die(_ s: String, _ code: Int32 = 1) -> Never {
    eprint("error: " + s)
    exit(code)
}

func msleep(_ ms: Int) { if ms > 0 { usleep(useconds_t(ms) * 1000) } }

func fmt(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
}

func num(_ s: String, _ what: String) -> Double {
    guard let v = Double(s) else { die("\(what) must be a number, got '\(s)'") }
    return v
}

/// Minimal argument parser: options are removed by name, whatever is left is positional.
/// Negative numbers ("-60") are positional because options always start with "--".
struct Args {
    var rest: [String]
    init(_ a: [String]) { rest = a }

    mutating func flag(_ name: String) -> Bool {
        guard let i = rest.firstIndex(of: name) else { return false }
        rest.remove(at: i)
        return true
    }

    mutating func values(_ name: String, count: Int = 1) -> [String]? {
        guard let i = rest.firstIndex(of: name) else { return nil }
        guard i + count < rest.count else { die("\(name) needs \(count) value(s)") }
        let v = Array(rest[(i + 1)...(i + count)])
        rest.removeSubrange(i...(i + count))
        return v
    }

    mutating func string(_ name: String) -> String? { values(name)?.first }

    mutating func int(_ name: String, default d: Int) -> Int {
        guard let s = string(name) else { return d }
        return Int(num(s, name))
    }

    mutating func double(_ name: String, default d: Double) -> Double {
        guard let s = string(name) else { return d }
        return num(s, name)
    }

    /// Call after all options were read: rejects leftovers like "--typo".
    func positional(_ n: Int, _ usageLine: String) -> [String] {
        if let bad = rest.first(where: { $0.hasPrefix("--") }) { die("unknown option \(bad)\nusage: \(usageLine)") }
        guard rest.count == n else { die("usage: \(usageLine)") }
        return rest
    }
}

// MARK: - Finding the iPhone Mirroring app and window

/// Bundle id of /System/Applications/iPhone Mirroring.app. The app and window owner names are localized
/// ("iPhone Mirroring", "Espelhamento do iPhone"...), so the bundle id is the reliable key. Note that
/// unrelated processes also contain "Espelhamento"/"Mirroring" (AirPlay), so never match by substring.
let mirroringBundleID = "com.apple.ScreenContinuity"
var knownOwnerNames: Set<String> = ["iPhone Mirroring", "Espelhamento do iPhone"]
if let extra = ProcessInfo.processInfo.environment["IPHONE_MIRROR_APP_NAME"] { knownOwnerNames.insert(extra) }

func mirroringApp() -> NSRunningApplication? {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: mirroringBundleID).first { return app }
    return NSWorkspace.shared.runningApplications.first { knownOwnerNames.contains($0.localizedName ?? "") }
}

struct MirrorWindow {
    let number: CGWindowID
    let pid: pid_t
    let owner: String
    /// Global display points, origin at the top-left of the main display. Negative on displays placed
    /// left of or above the main one.
    let bounds: CGRect
    let onScreen: Bool
}

func mirrorWindows() -> [MirrorWindow] {
    let app = mirroringApp()
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var found: [MirrorWindow] = []
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        let ours = app.map { $0.processIdentifier == pid } ?? knownOwnerNames.contains(owner)
        guard ours, (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
        guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
        // The app also owns thin, menu-bar-sized helper windows; the phone window is tall.
        guard r.height >= 200, r.width >= 150 else { continue }
        let on = (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        found.append(MirrorWindow(number: CGWindowID(n), pid: pid, owner: owner, bounds: r, onScreen: on))
    }
    // On-screen first, then the largest.
    return found.sorted {
        ($0.onScreen ? 1 : 0, $0.bounds.width * $0.bounds.height) > ($1.onScreen ? 1 : 0, $1.bounds.width * $1.bounds.height)
    }
}

func requireWindow() -> MirrorWindow {
    guard mirroringApp() != nil else {
        die("iPhone Mirroring is not running. Open it with: open -b \(mirroringBundleID)", 2)
    }
    guard let w = mirrorWindows().first else {
        die("iPhone Mirroring is running but has no window. Click its Dock icon or reopen it.", 2)
    }
    guard w.onScreen else {
        die("the iPhone Mirroring window is not on screen (minimized, hidden or on another Space). Bring it into view.", 2)
    }
    return w
}

/// Backing scale (pixels per point) of the display under the window's centre: 2 on Retina, 1 otherwise.
func displayScale(for rect: CGRect) -> Double {
    var id: CGDirectDisplayID = 0
    var n: UInt32 = 0
    if CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 1, &id, &n) != .success || n == 0 {
        if CGGetDisplaysWithRect(rect, 1, &id, &n) != .success || n == 0 { return 1 }
    }
    for s in NSScreen.screens {
        if let sn = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, sn.uint32Value == id {
            return Double(s.backingScaleFactor)
        }
    }
    if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 { return Double(mode.pixelWidth) / Double(mode.width) }
    return 1
}

// MARK: - Images

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("cannot read image \(path)") }
    return img
}

func savePNG(_ img: CGImage, _ path: String) {
    guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        die("cannot write \(path)")
    }
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { die("cannot write \(path)") }
}

func rgbaContext(_ w: Int, _ h: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { die("cannot allocate a \(w)x\(h) image") }
    ctx.interpolationQuality = .high
    return ctx
}

func resized(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage {
    let ctx = rgbaContext(w, h)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// RGBA bytes, row 0 = top of the image.
struct Pixels {
    let data: [UInt8]
    let width: Int
    let height: Int
    init(_ img: CGImage) {
        width = img.width
        height = img.height
        let ctx = rgbaContext(width, height)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        data = Array(UnsafeBufferPointer(start: ptr, count: width * height * 4))
    }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
}

func hex(_ c: (Int, Int, Int)) -> String { String(format: "#%02X%02X%02X", c.0, c.1, c.2) }

func parseHex(_ s: String) -> (Int, Int, Int) {
    var t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("#") { t.removeFirst() }
    guard t.count == 6, let v = Int(t, radix: 16) else { die("colour must look like #RRGGBB, got '\(s)'") }
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)
}

// MARK: - Screen capture

/// Runs `screencapture -x -o -l <window>`: -x no sound, -o no shadow, -l one window (even if covered).
func tryCapture(_ w: MirrorWindow, to path: String) -> (CGImage?, String) {
    try? FileManager.default.removeItem(atPath: path)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-t", "png", "-l", String(w.number), path]
    let pipe = Pipe()
    p.standardError = pipe
    p.standardOutput = pipe
    do { try p.run() } catch { return (nil, "cannot run screencapture: \(error)") }
    p.waitUntilExit()
    let msg = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: path),
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        return (nil, msg.isEmpty ? "screencapture produced no image" : msg)
    }
    return (img, msg)
}

let captureHelp = """
This usually means the app running this shell lacks Screen & System Audio Recording permission. \
Grant it in System Settings > Privacy & Security, then quit that app completely (cmd+Q) and reopen it. \
Run `iphone-mirror doctor` for details.
"""

/// Takes a screenshot and, unless `native`, downsizes it to window points so 1 px = 1 pt.
@discardableResult
func takeShot(_ path: String, native: Bool) -> (CGImage, MirrorWindow) {
    let w = requireWindow()
    let (captured, msg) = tryCapture(w, to: path)
    guard var img = captured else { die("screenshot failed: \(msg). \(captureHelp)", 3) }
    let pw = Int(w.bounds.width.rounded()), ph = Int(w.bounds.height.rounded())
    if !native && (img.width != pw || img.height != ph) {
        img = resized(img, pw, ph)
        savePNG(img, path)
    }
    let scale = Double(img.width) / Double(w.bounds.width)
    var line = "\(path) \(img.width)x\(img.height) scale=\(fmt(scale))"
    if abs(scale - 1) > 0.01 { line += " (pass --ref \(path) or --scale \(fmt(scale)) when tapping)" }
    print(line)
    return (img, w)
}

// MARK: - Coordinates, activation, safety

func scaleOption(_ a: inout Args, _ w: MirrorWindow) -> Double {
    if let s = a.string("--scale") {
        let v = num(s, "--scale")
        guard v > 0 else { die("--scale must be > 0") }
        return v
    }
    if let ref = a.string("--ref") { return Double(loadImage(ref).width) / Double(w.bounds.width) }
    return 1
}

/// Screenshot pixel -> global screen point. Refuses points outside the phone window, so a bad
/// coordinate can never click some other app.
func toScreen(_ x: Double, _ y: Double, _ s: Double, _ w: MirrorWindow) -> CGPoint {
    let px = x / s, py = y / s
    guard px >= 0, py >= 0, px < Double(w.bounds.width), py < Double(w.bounds.height) else {
        die("(\(fmt(x)), \(fmt(y))) is outside the window; screenshots are \(Int(Double(w.bounds.width) * s))x\(Int(Double(w.bounds.height) * s)) px at scale \(fmt(s)). Take a fresh shot.")
    }
    return CGPoint(x: Double(w.bounds.minX) + px, y: Double(w.bounds.minY) + py)
}

func axFrontmost(_ pid: pid_t) -> Bool {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, &v) == .success else {
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
    return (v as? Bool) ?? false
}

func bringToFront(_ w: MirrorWindow) {
    if axFrontmost(w.pid) { return }
    NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    for _ in 0..<20 where !axFrontmost(w.pid) { msleep(50) }
    msleep(200)
}

/// Name of another app's window drawn above `p`, if any (the click would go there instead).
func coveringWindow(at p: CGPoint, _ ours: MirrorWindow) -> String? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list { // front to back
        let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        if n == ours.number { return nil }
        let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        // Skip cursor/overlay levels, invisible windows and the app's own helper windows.
        if layer < 0 || layer >= 1000 || alpha < 0.05 || owner == "Window Server" || pid == ours.pid { continue }
        guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.contains(p) else { continue }
        return owner.isEmpty ? "an unnamed window" : owner
    }
    return nil
}

/// Shared prologue of tap/scroll/swipe: permission check, --dry-run, activation, "is something in the way?".
/// Without Accessibility, macOS silently drops synthetic events, so fail loudly instead of "succeeding".
func prepare(_ w: MirrorWindow, _ points: [CGPoint], activate: Bool, force: Bool, dryRun: Bool, what: String) {
    if dryRun {
        let pts = points.map { "(\(fmt(Double($0.x))), \(fmt(Double($0.y))))" }.joined(separator: " -> ")
        print("dry run: would \(what) at global screen point(s) \(pts); nothing was sent")
        exit(0)
    }
    guard AXIsProcessTrusted() else {
        die("Accessibility permission is missing for the app running this shell, so macOS would drop the events. Run `iphone-mirror doctor`.", 3)
    }
    if activate { bringToFront(w) }
    for p in points {
        if let other = coveringWindow(at: p, w), !force {
            die("\(other) covers the target point, so the click would go there. Move that window or pass --force.")
        }
    }
}

// MARK: - Synthetic input

let eventSource = CGEventSource(stateID: .hidSystemState)

func pointerLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func postMouse(_ type: CGEventType, _ p: CGPoint) {
    guard let e = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    e.post(tap: .cghidEventTap)
}

/// Moves the pointer to `target` in small steps. iPhone Mirroring only updates the phone-side pointer from
/// movement events, so this is what makes the following click land in the right place.
func glide(to target: CGPoint, within win: CGRect, steps: Int, stepMs: Int = 12) {
    var start = pointerLocation()
    if hypot(start.x - target.x, start.y - target.y) < 4 {
        // Already on target: still send movement, coming from a nearby point inside the window.
        start = CGPoint(x: max(win.minX + 1, target.x - 15), y: max(win.minY + 1, target.y - 15))
        postMouse(.mouseMoved, start)
        msleep(stepMs)
    }
    let n = max(2, steps)
    for i in 1...n {
        let t = Double(i) / Double(n)
        postMouse(.mouseMoved, CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
        msleep(stepMs)
    }
}

struct AfterShot {
    let path: String?
    let delay: Int
    init(_ a: inout Args, defaultDelay: Int) {
        path = a.string("--shot")
        delay = a.int("--delay", default: defaultDelay)
    }
    func run() {
        guard let path else { return }
        msleep(delay)
        takeShot(path, native: false)
    }
}

// MARK: - Commands

func cmdShot(_ a: inout Args) {
    let native = a.flag("--native")
    let p = a.positional(1, "iphone-mirror shot <out.png> [--native]")
    takeShot(p[0], native: native)
}

func cmdTap(_ a: inout Args) {
    let hold = a.int("--hold", default: 120)
    let wait = a.int("--wait", default: 500)
    let steps = a.int("--steps", default: 25)
    let activate = !a.flag("--no-activate")
    let force = a.flag("--force")
    let dryRun = a.flag("--dry-run")
    let after = AfterShot(&a, defaultDelay: 1000)
    let w = requireWindow()
    let s = scaleOption(&a, w)
    let p = a.positional(2, "iphone-mirror tap <x> <y> [--hold ms] [--wait ms] [--ref img | --scale s] [--shot out.png]")
    let x = num(p[0], "x"), y = num(p[1], "y")
    let pt = toScreen(x, y, s, w)
    prepare(w, [pt], activate: activate, force: force, dryRun: dryRun, what: "tap \(fmt(x)),\(fmt(y))")
    glide(to: pt, within: w.bounds, steps: steps)
    msleep(wait)
    postMouse(.leftMouseDown, pt)
    msleep(hold)
    postMouse(.leftMouseUp, pt)
    print("tapped \(fmt(x)),\(fmt(y))\(hold >= 500 ? " (long press \(hold) ms)" : "")")
    after.run()
}

func cmdScroll(_ a: inout Args) {
    let times = a.int("--times", default: 8)
    let interval = a.int("--interval", default: 30)
    let settle = a.int("--settle", default: 2500)
    let at = a.values("--at", count: 2)
    let activate = !a.flag("--no-activate")
    let force = a.flag("--force")
    let dryRun = a.flag("--dry-run")
    let after = AfterShot(&a, defaultDelay: 0)
    let w = requireWindow()
    let s = scaleOption(&a, w)
    let p = a.positional(1, "iphone-mirror scroll <dy> [--at x y] [--times n] [--settle ms] [--shot out.png]")
    guard let dy = Int32(p[0]) else { die("dy must be an integer number of pixels, e.g. -60") }
    let target = at.map { toScreen(num($0[0], "x"), num($0[1], "y"), s, w) }
        ?? CGPoint(x: w.bounds.midX, y: w.bounds.midY)
    prepare(w, [target], activate: activate, force: force, dryRun: dryRun, what: "scroll \(dy) x \(max(1, times))")
    glide(to: target, within: w.bounds, steps: 15)
    msleep(300)
    for _ in 0..<max(1, times) {
        CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        msleep(interval)
    }
    // A tap during scroll momentum only stops the scroll, so let it finish.
    msleep(settle)
    print("scrolled \(dy) x \(max(1, times))")
    after.run()
}

func cmdSwipe(_ a: inout Args) {
    let duration = a.int("--duration", default: 300)
    let settle = a.int("--settle", default: 1000)
    let activate = !a.flag("--no-activate")
    let force = a.flag("--force")
    let dryRun = a.flag("--dry-run")
    let after = AfterShot(&a, defaultDelay: 0)
    let w = requireWindow()
    let s = scaleOption(&a, w)
    let p = a.positional(4, "iphone-mirror swipe <x1> <y1> <x2> <y2> [--duration ms] [--shot out.png]")
    let p1 = toScreen(num(p[0], "x1"), num(p[1], "y1"), s, w)
    let p2 = toScreen(num(p[2], "x2"), num(p[3], "y2"), s, w)
    prepare(w, [p1, p2], activate: activate, force: force, dryRun: dryRun, what: "swipe")
    glide(to: p1, within: w.bounds, steps: 25)
    msleep(500)
    postMouse(.leftMouseDown, p1)
    msleep(80)
    let steps = max(8, duration / 12)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        postMouse(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t))
        msleep(max(1, duration / steps))
    }
    msleep(60)
    postMouse(.leftMouseUp, p2)
    msleep(settle)
    print("swiped \(p[0]),\(p[1]) -> \(p[2]),\(p[3]) (experimental)")
    after.run()
}

// Menu items, found through the Accessibility API (no AppleScript, so no extra Automation permission).

struct MenuEntry {
    let path: [String]
    let element: AXUIElement
    let shortcut: String
    let modifiers: Int
    let enabled: Bool
    var title: String { path.last ?? "" }
}

func axValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

func menuEntries(_ pid: pid_t) -> [MenuEntry] {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &v)
    if err == .apiDisabled || !AXIsProcessTrusted() {
        die("Accessibility permission is missing for the app running this shell. Run `iphone-mirror doctor`.", 3)
    }
    guard err == .success, let bar = v, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
    var out: [MenuEntry] = []
    func walk(_ el: AXUIElement, _ path: [String], _ depth: Int) {
        guard depth < 6 else { return }
        let kids = (axValue(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for (i, c) in kids.enumerated() {
            let role = axValue(c, kAXRoleAttribute) as? String ?? ""
            let title = axValue(c, kAXTitleAttribute) as? String ?? ""
            switch role {
            case kAXMenuBarItemRole:
                if depth == 0 && i == 0 { continue } // the Apple menu (Shut Down, Log Out...): never touch it
                walk(c, path + [title], depth + 1)
            case kAXMenuRole:
                walk(c, path, depth + 1)
            case kAXMenuItemRole:
                if !title.isEmpty {
                    out.append(MenuEntry(path: path + [title], element: c,
                                         shortcut: axValue(c, kAXMenuItemCmdCharAttribute) as? String ?? "",
                                         modifiers: (axValue(c, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0,
                                         enabled: (axValue(c, kAXEnabledAttribute) as? Bool) ?? true))
                }
                walk(c, path + [title], depth + 1) // submenus
            default:
                break
            }
        }
    }
    walk(bar as! AXUIElement, [], 0)
    return out
}

/// Known actions with their localized titles. Add a title here if your macOS language is missing;
/// `menu --list` shows the exact titles. Matching ignores case and accents.
let menuActions: [String: [String]] = [
    "home": ["Home Screen", "Tela de Início", "Tela Inicial", "Pantalla de inicio", "Écran d'accueil",
             "Home-Bildschirm", "Schermata Home"],
    "appswitcher": ["App Switcher", "Seletor de Apps", "Selector de apps", "Sélecteur d'apps", "App-Umschalter"],
    "spotlight": ["Spotlight"],
    "paste": ["Paste", "Colar", "Pegar", "Coller", "Einsetzen", "Incolla"],
]

func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "…", with: "")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        .trimmingCharacters(in: .whitespaces)
}

func shortcutLabel(_ e: MenuEntry) -> String {
    guard !e.shortcut.isEmpty else { return "" }
    var m = ""
    if e.modifiers & 4 != 0 { m += "ctrl+" }
    if e.modifiers & 2 != 0 { m += "opt+" }
    if e.modifiers & 1 != 0 { m += "shift+" }
    if e.modifiers & 8 == 0 { m += "cmd+" }
    return m + e.shortcut
}

func cmdMenu(_ a: inout Args) {
    let list = a.flag("--list")
    let activate = !a.flag("--no-activate")
    let after = AfterShot(&a, defaultDelay: 1000)
    guard let app = mirroringApp() else { die("iPhone Mirroring is not running. Open it with: open -b \(mirroringBundleID)", 2) }
    let entries = menuEntries(app.processIdentifier)
    if list {
        if a.rest.count > 0 { die("usage: iphone-mirror menu --list") }
        for e in entries {
            let sc = shortcutLabel(e)
            print(e.path.joined(separator: " > ") + (sc.isEmpty ? "" : "  [\(sc)]") + (e.enabled ? "" : "  (disabled)"))
        }
        return
    }
    let p = a.positional(1, "iphone-mirror menu <home|app-switcher|spotlight|paste|\"Exact Title\"> | menu --list")
    let key = p[0].lowercased().filter { $0.isLetter }
    let aliasKey = ["home": "home", "homescreen": "home", "appswitcher": "appswitcher", "switcher": "appswitcher",
                    "spotlight": "spotlight", "search": "spotlight", "paste": "paste"][key]
    let wanted = Set((aliasKey.flatMap { menuActions[$0] } ?? [p[0]]).map(normalize))
    let matches = entries.filter { wanted.contains(normalize($0.title)) }
    guard let item = matches.first(where: { $0.enabled }) ?? matches.first else {
        die("no menu item named \(wanted.sorted().joined(separator: " / ")). Run `iphone-mirror menu --list` to see the titles on this Mac.", 4)
    }
    guard item.enabled else { die("menu item \(item.path.joined(separator: " > ")) is disabled right now", 4) }
    if activate, let w = mirrorWindows().first { bringToFront(w) }
    let r = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
    guard r == .success else { die("pressing \(item.path.joined(separator: " > ")) failed (AXError \(r.rawValue))") }
    print("pressed \(item.path.joined(separator: " > "))")
    after.run()
}

/// Small grayscale thumbnail used to compare consecutive frames.
func signature(_ img: CGImage, _ region: CGRect?) -> [UInt8] {
    var src = img
    if let r = region, let c = img.cropping(to: r) { src = c }
    let w = 64, h = max(1, Int(Double(64 * src.height) / Double(max(1, src.width))))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
    ctx.interpolationQuality = .medium
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
    let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
    return Array(UnsafeBufferPointer(start: ptr, count: w * h))
}

func cmdWaitSettle(_ a: inout Args) {
    let timeout = a.int("--timeout", default: 8000)
    let interval = a.int("--interval", default: 300)
    let threshold = a.double("--threshold", default: 0.004)
    let regionArgs = a.values("--region", count: 4)
    _ = a.positional(0, "iphone-mirror wait-settle [--timeout ms] [--interval ms] [--region x1 y1 x2 y2]")
    let w = requireWindow()
    let tmp = NSTemporaryDirectory() + "iphone-mirror-settle-\(getpid()).png"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let start = Date()
    var prev: [UInt8]? = nil
    var calm = 0
    var lastChange = 1.0
    while true {
        let (img, msg) = tryCapture(w, to: tmp)
        guard let img else { die("screenshot failed: \(msg). \(captureHelp)", 3) }
        var region: CGRect? = nil
        if let r = regionArgs {
            let k = Double(img.width) / Double(w.bounds.width) // region is given in 1x screenshot pixels
            let v = r.map { num($0, "--region") * k }
            region = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
        }
        let sig = signature(img, region)
        if let p = prev, p.count == sig.count, !sig.isEmpty {
            let changed = zip(p, sig).filter { abs(Int($0) - Int($1)) > 10 }.count
            lastChange = Double(changed) / Double(sig.count)
            calm = lastChange <= threshold ? calm + 1 : 0
            if calm >= 2 {
                print("settled after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                return
            }
        }
        prev = sig
        if Date().timeIntervalSince(start) * 1000 > Double(timeout) {
            print("still changing after \(String(format: "%.1f", Date().timeIntervalSince(start)))s (\(String(format: "%.1f", lastChange * 100))% of the screen moving; a playing video never settles, use --region or a fixed sleep)")
            exit(4)
        }
        msleep(interval)
    }
}

func cmdColor(_ a: inout Args) {
    let p = a.rest
    guard p.count >= 3, p.count % 2 == 1 else { die("usage: iphone-mirror color <img.png> <x> <y> [<x> <y> ...]") }
    let px = Pixels(loadImage(p[0]))
    for i in stride(from: 1, to: p.count, by: 2) {
        let x = Int(num(p[i], "x")), y = Int(num(p[i + 1], "y"))
        guard x >= 0, y >= 0, x < px.width, y < px.height else { die("(\(x), \(y)) is outside the \(px.width)x\(px.height) image") }
        print("\(x),\(y) \(hex(px.rgb(x, y)))")
    }
}

func cmdHasColor(_ a: inout Args) {
    let tol = a.int("--tol", default: 40)
    let step = max(1, a.int("--step", default: 1))
    let p = a.positional(6, "iphone-mirror has-color <img.png> <x1> <y1> <x2> <y2> <#RRGGBB> [--tol 40]")
    let px = Pixels(loadImage(p[0]))
    let want = parseHex(p[5])
    let xs = [Int(num(p[1], "x1")), Int(num(p[3], "x2"))].map { min(max($0, 0), px.width - 1) }
    let ys = [Int(num(p[2], "y1")), Int(num(p[4], "y2"))].map { min(max($0, 0), px.height - 1) }
    for y in stride(from: ys.min()!, through: ys.max()!, by: step) {
        for x in stride(from: xs.min()!, through: xs.max()!, by: step) {
            let c = px.rgb(x, y)
            if max(abs(c.0 - want.0), abs(c.1 - want.1), abs(c.2 - want.2)) <= tol {
                print("found \(hex(c)) at \(x),\(y)")
                return
            }
        }
    }
    print("not found")
    exit(4)
}

func cmdJoin(_ a: inout Args) {
    let trimBars = a.flag("--trim-bars")
    let top = a.int("--crop-top", default: -1)
    let bottom = a.int("--crop-bottom", default: -1)
    let gap = a.int("--gap", default: 6)
    let factor = a.double("--resize", default: 1)
    if let bad = a.rest.first(where: { $0.hasPrefix("--") }) { die("unknown option \(bad)") }
    guard a.rest.count >= 2 else {
        die("usage: iphone-mirror join <out.png> <a.png> [b.png ...] [--crop-top px] [--crop-bottom px] [--trim-bars] [--gap px] [--resize f]")
    }
    let out = a.rest[0]
    var images: [CGImage] = []
    for path in a.rest.dropFirst() {
        let img = loadImage(path)
        // --trim-bars: drop the iOS status bar (~6.5% of the height) and home indicator strip (~2.7%).
        let t = top >= 0 ? top : (trimBars ? Int(Double(img.height) * 0.065) : 0)
        let b = bottom >= 0 ? bottom : (trimBars ? Int(Double(img.height) * 0.027) : 0)
        guard t + b < img.height, let c = img.cropping(to: CGRect(x: 0, y: t, width: img.width, height: img.height - t - b)) else {
            die("crop is larger than \(path)")
        }
        images.append(c)
    }
    let width = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
    let height = images.map(\.height).max()!
    let ctx = rgbaContext(width, height)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var x = 0
    for img in images {
        ctx.draw(img, in: CGRect(x: x, y: height - img.height, width: img.width, height: img.height)) // top-aligned
        x += img.width + gap
    }
    var result = ctx.makeImage()!
    if factor > 0 && abs(factor - 1) > 0.001 {
        result = resized(result, max(1, Int(Double(width) * factor)), max(1, Int(Double(height) * factor)))
    }
    savePNG(result, out)
    print("\(out) \(result.width)x\(result.height) from \(images.count) image(s)")
}

func cmdInfo(_ a: inout Args) {
    _ = a.positional(0, "iphone-mirror info")
    let app = mirroringApp()
    var d: [String: Any] = [
        "running": app != nil,
        "accessibility": AXIsProcessTrusted(),
        "screenRecording": CGPreflightScreenCaptureAccess(),
    ]
    if let app {
        d["app"] = app.localizedName ?? ""
        d["bundleId"] = app.bundleIdentifier ?? ""
        d["pid"] = Int(app.processIdentifier)
        d["frontmost"] = axFrontmost(app.processIdentifier)
    }
    if let w = mirrorWindows().first {
        let s = displayScale(for: w.bounds)
        d["window"] = Int(w.number)
        d["onScreen"] = w.onScreen
        d["x"] = Double(w.bounds.minX)
        d["y"] = Double(w.bounds.minY)
        d["width"] = Double(w.bounds.width)
        d["height"] = Double(w.bounds.height)
        d["displayScale"] = s
        d["shotSize"] = "\(Int(w.bounds.width))x\(Int(w.bounds.height))"
        d["nativeShotSize"] = "\(Int(Double(w.bounds.width) * s))x\(Int(Double(w.bounds.height) * s))"
    }
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    if app == nil || d["window"] == nil { exit(2) }
}

// Host app detection: the permissions belong to the .app that (indirectly) started this process.

func parentPID(_ pid: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
    return pid_t(info.pbi_ppid)
}

func processPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

func hostApp() -> (name: String, path: String)? {
    var pid = getpid()
    for _ in 0..<64 where pid > 1 {
        let path = processPath(pid)
        if let r = path.range(of: ".app/") { // outermost bundle, e.g. /Applications/Foo.app
            let appPath = String(path[..<r.lowerBound]) + ".app"
            let name = FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
            return (name, appPath)
        }
        pid = parentPID(pid)
    }
    return nil
}

func cmdDoctor(_ a: inout Args) {
    let prompt = a.flag("--prompt")
    _ = a.positional(0, "iphone-mirror doctor [--prompt]")
    var problems = 0
    func ok(_ s: String) { print("[ok]   " + s) }
    func warn(_ s: String) { print("[warn] " + s) }
    func fail(_ s: String, _ fix: String) {
        problems += 1
        print("[FAIL] " + s)
        print("       fix: " + fix)
    }

    print("iphone-mirror \(toolVersion) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    let host = hostApp()
    let hostName = host?.name ?? "the app that runs this shell"
    if let host {
        ok("host app: \(host.name) (\(host.path)); permissions must be granted to this app")
    } else {
        warn("no .app found among the parent processes (tmux, ssh or a daemon?). Grant the permissions to the terminal or agent app that started this shell, then restart it (and the tmux server, if any).")
    }

    let trusted = prompt
        ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        : AXIsProcessTrusted()
    if trusted {
        ok("Accessibility: granted (taps, scrolls, menus)")
    } else {
        fail("Accessibility: not granted to \(hostName) (taps, scrolls and menus will do nothing)",
             "System Settings > Privacy & Security > Accessibility > enable \(hostName). Open it with: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")
    }

    let screenOK = CGPreflightScreenCaptureAccess()
    if !screenOK && prompt { _ = CGRequestScreenCaptureAccess() }

    guard let app = mirroringApp() else {
        fail("iPhone Mirroring is not running", "open -b \(mirroringBundleID)   (then unlock or confirm on the Mac if it asks)")
        exit(1)
    }
    ok("iPhone Mirroring running: \"\(app.localizedName ?? "?")\" pid \(app.processIdentifier)")

    guard let w = mirrorWindows().first, w.onScreen else {
        fail("no on-screen iPhone Mirroring window", "un-minimize it or switch to its Space; the window must be visible on a display")
        exit(1)
    }
    let s = displayScale(for: w.bounds)
    ok("window #\(w.number) at (\(fmt(Double(w.bounds.minX))), \(fmt(Double(w.bounds.minY)))) size \(fmt(Double(w.bounds.width)))x\(fmt(Double(w.bounds.height))) pt, display scale \(fmt(s))")

    let tmp = NSTemporaryDirectory() + "iphone-mirror-doctor-\(getpid()).png"
    let (img, msg) = tryCapture(w, to: tmp)
    try? FileManager.default.removeItem(atPath: tmp)
    if let img {
        ok("Screen Recording: screenshot works, native \(img.width)x\(img.height) px (\(fmt(Double(img.width) / Double(w.bounds.width)))x); `shot` saves \(Int(w.bounds.width))x\(Int(w.bounds.height))")
    } else {
        fail("Screen Recording: screenshot failed (\(msg))",
             "System Settings > Privacy & Security > Screen & System Audio Recording > enable \(hostName), then QUIT \(hostName) with cmd+Q and reopen it (the permission only applies after a restart). Open it with: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
    }

    if let other = coveringWindow(at: CGPoint(x: w.bounds.midX, y: w.bounds.midY), w) {
        warn("\(other) is drawn above the phone window's centre; actions bring iPhone Mirroring to the front first")
    }
    print(problems == 0
          ? "All good. If taps still do nothing, ask the user to click once inside the iPhone Mirroring window."
          : "\(problems) problem(s) found.")
    exit(problems == 0 ? 0 : 1)
}

// MARK: - Main

var argv = Args(Array(CommandLine.arguments.dropFirst()))
guard let command = argv.rest.first else {
    print(usage)
    exit(1)
}
argv.rest.removeFirst()

switch command {
case "doctor": cmdDoctor(&argv)
case "info": cmdInfo(&argv)
case "shot", "screenshot": cmdShot(&argv)
case "tap", "click": cmdTap(&argv)
case "scroll": cmdScroll(&argv)
case "swipe", "drag": cmdSwipe(&argv)
case "menu": cmdMenu(&argv)
case "wait-settle", "settle": cmdWaitSettle(&argv)
case "color", "colour": cmdColor(&argv)
case "has-color", "has-colour": cmdHasColor(&argv)
case "join": cmdJoin(&argv)
case "version", "--version": print(toolVersion)
case "help", "--help", "-h": print(usage)
default: die("unknown command '\(command)'. Run `iphone-mirror help`.")
}
