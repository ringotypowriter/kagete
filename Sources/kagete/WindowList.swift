import AppKit
import CoreGraphics

struct WindowRecord: Codable {
    let windowId: UInt32
    let pid: Int32
    let app: String?
    let bundleId: String?
    let title: String?
    let bounds: BoundsJSON
    let layer: Int
    let onScreen: Bool
}

enum WindowList {
    static func all(filterPid: pid_t? = nil) -> [WindowRecord] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let bundlesByPid: [pid_t: String] = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap {
                guard let b = $0.bundleIdentifier else { return nil }
                return ($0.processIdentifier, b)
            })

        return raw.compactMap { dict -> WindowRecord? in
            guard
                let wid = dict[kCGWindowNumber as String] as? UInt32,
                let pid = dict[kCGWindowOwnerPID as String] as? Int32
            else { return nil }
            if let want = filterPid, pid != want { return nil }

            let layer = (dict[kCGWindowLayer as String] as? Int) ?? 0
            // Layer 0 is normal app windows. Skip menu bars, dock, etc.
            if layer != 0 { return nil }

            let name = dict[kCGWindowOwnerName as String] as? String
            let title = dict[kCGWindowName as String] as? String
            let boundsDict = (dict[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
            let rect = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0)
            let onScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? true

            return WindowRecord(
                windowId: wid,
                pid: pid,
                app: name,
                bundleId: bundlesByPid[pid],
                title: title,
                bounds: BoundsJSON(rect),
                layer: layer,
                onScreen: onScreen)
        }
    }
}
