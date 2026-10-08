import AppKit
import ShotCore

/// A window on screen at the moment of the snapshot.
public struct WindowInfo: Hashable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    /// Empty without the screen recording permission.
    public let title: String
    /// Screen space.
    public let frame: CGRect
    public let layer: Int
    public let bundleID: String?

    /// "Окно «Заметки»", or just "Окно" for windows without a name.
    public var displayTitle: String {
        if !ownerName.isEmpty, layer == Int(CGWindowLevelForKey(.dockWindow)) { return ownerName }
        return ownerName.isEmpty ? L("Окно") : L("Окно «%@»", ownerName)
    }
}

public enum WindowList {
    /// On-screen windows from front to back, without the given ones (the app's own overlays) and without
    /// the menu bar, status items and invisible helper windows.
    public static func snapshot(excluding excluded: Set<CGWindowID> = []) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let displays = activeDisplayFrames()
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        var bundleIDs: [pid_t: String?] = [:]
        var result: [WindowInfo] = []

        for info in list {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else { continue }
            let pid = pid_t(pidNumber.int32Value)
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String ?? ""

            guard !excluded.contains(CGWindowID(number.uint32Value)), alpha > 0.05, frame.width >= 12,
                  frame.height >= 12 else { continue }
            guard layer >= 0, layer <= popUpLevel, layer != menuLevel, layer != statusLevel else { continue }
            if owner == "Window Server" || owner == "WindowManager" { continue }
            // Full-screen helpers above normal windows (Notification Center, Dock's Mission Control layer…)
            // are transparent; a real full-screen app window sits on the normal layer.
            if layer != 0, displays.contains(where: { $0.isClose(to: frame, tolerance: 2) }) { continue }

            if bundleIDs[pid] == nil {
                bundleIDs[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            result.append(WindowInfo(id: CGWindowID(number.uint32Value), pid: pid, ownerName: owner, title: title,
                                     frame: frame, layer: layer, bundleID: bundleIDs[pid] ?? nil))
        }
        return result
    }

    /// The front-most window that contains the point.
    public static func window(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.frame.contains(point) }
    }

    static func activeDisplayFrames() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map(CGDisplayBounds)
    }
}
