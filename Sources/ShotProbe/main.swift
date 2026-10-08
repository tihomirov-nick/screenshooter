import AppKit
import Detection
import ScreenCaptureKit
import ShotCore

// Checks region detection on the live screen without the app's UI. Runs with the permissions of the
// terminal it is started from (accessibility for elements, screen recording for pixel analysis).
// Prints rectangles and kinds only, never pixels.
//
//   shotprobe windows                      on-screen windows, front to back
//   shotprobe at X Y [--pixels]            regions under a point (screen space: top-left origin, points)
//   shotprobe follow [SECONDS] [--pixels]  regions under the mouse, printed whenever they change
//
// --pixels freezes the displays first and adds the boxes and text blocks found in the pixels.

func describe(_ rect: CGRect) -> String {
    String(format: "%5.0f,%5.0f  %4.0f×%-4.0f", rect.minX, rect.minY, rect.width, rect.height)
}

func printChain(at point: CGPoint, detector: RegionDetector) {
    let start = Date()
    let chain = detector.chainSync(at: point)
    let ms = Date().timeIntervalSince(start) * 1000
    let pick = RegionChain.defaultIndex(in: chain)
    print(String(format: "— at %.0f,%.0f (%.1f ms)", point.x, point.y, ms))
    for (i, region) in chain.enumerated() {
        let mark = i == pick ? "▶" : " "
        print("  \(mark) \(describe(region.rect))  [\(region.source.rawValue)] \(region.title)")
    }
}

/// Every display, as the app freezes them.
func freezeDisplays() -> [DisplaySnapshot] {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: [DisplaySnapshot] = []
    Task.detached {
        defer { done.signal() }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            print("screen recording: NOT granted")
            return
        }
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                result.append(DisplaySnapshot(displayID: display.displayID, frame: display.frame, scale: scale, image: image))
            }
        }
    }
    done.wait()
    return result
}

func makeDetector(pixels: Bool) -> RegionDetector {
    var options = RegionDetector.Options()
    options.shapes = pixels
    options.text = pixels
    let windows = WindowList.snapshot()
    AccessibilityBooster.shared.boost(windows)
    let displays = pixels ? freezeDisplays() : []
    let detector = RegionDetector(displays: displays, windows: windows, options: options)
    // Pixel analysis runs in the background; web apps build their tree after the boost.
    RunLoop.main.run(until: Date().addingTimeInterval(pixels ? 0.6 : 0.3))
    return detector
}

var args = Array(CommandLine.arguments.dropFirst())
let pixels = args.contains("--pixels")
args.removeAll { $0 == "--pixels" }
print("accessibility: \(AccessibilityRegions.isTrusted ? "granted" : "NOT granted")")

switch args.first {
case "windows":
    for w in WindowList.snapshot() {
        print("\(describe(w.frame))  layer \(w.layer)  pid \(w.pid)  \(w.ownerName)  \(w.bundleID ?? "-")")
    }
case "at" where args.count >= 3:
    guard let x = Double(args[1]), let y = Double(args[2]) else { exit(1) }
    let detector = makeDetector(pixels: pixels)
    printChain(at: CGPoint(x: x, y: y), detector: detector)
case "follow":
    let seconds = args.count > 1 ? Double(args[1]) ?? 20 : 20
    let detector = makeDetector(pixels: pixels)
    var last: CGPoint?
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let p = ScreenGeometry.mouseLocation
        if last.map({ hypot($0.x - p.x, $0.y - p.y) > 2 }) ?? true {
            printChain(at: p, detector: detector)
            last = p
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }
default:
    print("usage: shotprobe windows | at X Y [--pixels] | follow [SECONDS] [--pixels]")
}
