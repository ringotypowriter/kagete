import ApplicationServices
import CoreGraphics
import Foundation

struct AXNode: Codable {
    let role: String?
    let subrole: String?
    let title: String?
    let value: String?
    let description: String?
    let identifier: String?
    let help: String?
    let enabled: Bool?
    let focused: Bool?
    let frame: BoundsJSON?
    let axPath: String
    let children: [AXNode]
}

enum AXInspector {
    static func inspect(pid: pid_t, windowFilter: String?, maxDepth: Int) throws -> AXNode {
        let chosen = try selectWindow(pid: pid, windowFilter: windowFilter)
        let rootSegment = pathSegment(
            role: copyAttr(chosen, kAXRoleAttribute) as? String,
            title: copyAttr(chosen, kAXTitleAttribute) as? String,
            identifier: copyAttr(chosen, kAXIdentifierAttribute) as? String)
        return walk(chosen, path: "/\(rootSegment)", depth: 0, maxDepth: maxDepth)
    }

    private static func walk(_ el: AXUIElement, path: String, depth: Int, maxDepth: Int) -> AXNode {
        let role = copyAttr(el, kAXRoleAttribute) as? String
        let subrole = copyAttr(el, kAXSubroleAttribute) as? String
        let title = copyAttr(el, kAXTitleAttribute) as? String
        let value = stringify(copyAttr(el, kAXValueAttribute))
        let description = copyAttr(el, kAXDescriptionAttribute) as? String
        let identifier = copyAttr(el, kAXIdentifierAttribute) as? String
        let help = copyAttr(el, kAXHelpAttribute) as? String
        let enabled = copyAttr(el, kAXEnabledAttribute) as? Bool
        let focused = copyAttr(el, kAXFocusedAttribute) as? Bool
        let frame = frameOf(el)

        var children: [AXNode] = []
        if depth < maxDepth, let kids = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement], !kids.isEmpty {
            let rawSegments: [String] = kids.map { child in
                pathSegment(
                    role: copyAttr(child, kAXRoleAttribute) as? String,
                    title: copyAttr(child, kAXTitleAttribute) as? String,
                    identifier: copyAttr(child, kAXIdentifierAttribute) as? String)
            }
            var counts: [String: Int] = [:]
            for seg in rawSegments { counts[seg, default: 0] += 1 }
            var nextIndex: [String: Int] = [:]
            children.reserveCapacity(kids.count)
            for (i, child) in kids.enumerated() {
                let base = rawSegments[i]
                let seg: String
                if (counts[base] ?? 0) > 1 {
                    let k = nextIndex[base, default: 0]
                    seg = "\(base)[\(k)]"
                    nextIndex[base] = k + 1
                } else {
                    seg = base
                }
                children.append(walk(child, path: "\(path)/\(seg)", depth: depth + 1, maxDepth: maxDepth))
            }
        }

        return AXNode(
            role: role, subrole: subrole, title: title, value: value,
            description: description, identifier: identifier, help: help,
            enabled: enabled, focused: focused, frame: frame,
            axPath: path, children: children)
    }

    static func pathSegment(role: String?, title: String?, identifier: String?) -> String {
        var seg = role ?? "AXElement"
        if let id = identifier, !id.isEmpty {
            seg += "[id=\"\(escape(id))\"]"
        } else if let t = title, !t.isEmpty {
            seg += "[title=\"\(escape(t))\"]"
        }
        return seg
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func copyAttr(_ el: AXUIElement, _ key: String) -> Any? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(el, key as CFString, &ref)
        guard result == .success else { return nil }
        return ref
    }

    private static func frameOf(_ el: AXUIElement) -> BoundsJSON? {
        guard
            let posRaw = copyAttr(el, kAXPositionAttribute),
            let sizeRaw = copyAttr(el, kAXSizeAttribute),
            CFGetTypeID(posRaw as CFTypeRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRaw as CFTypeRef) == AXValueGetTypeID()
        else { return nil }

        let posVal = posRaw as! AXValue
        let sizeVal = sizeRaw as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &point),
              AXValueGetValue(sizeVal, .cgSize, &size) else { return nil }
        return BoundsJSON(CGRect(origin: point, size: size))
    }

    private static func stringify(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    static func selectWindow(pid: pid_t, windowFilter: String?) throws -> AXUIElement {
        guard Permissions.accessibility else {
            throw KageteError.notTrusted(
                "Accessibility permission not granted. Run `kagete doctor --prompt` or grant it in System Settings → Privacy & Security → Accessibility.")
        }
        let appEl = AXUIElementCreateApplication(pid)
        let windows = (copyAttr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard !windows.isEmpty else {
            throw KageteError.notFound("No AX windows for pid \(pid).")
        }

        if let filter = windowFilter {
            guard let hit = windows.first(where: {
                (copyAttr($0, kAXTitleAttribute) as? String ?? "").localizedCaseInsensitiveContains(filter)
            }) else {
                let titles = windows
                    .map { (copyAttr($0, kAXTitleAttribute) as? String) ?? "(untitled)" }
                    .joined(separator: ", ")
                throw KageteError.notFound("No window matching \"\(filter)\". Available: \(titles)")
            }
            return hit
        }
        if let main = copyAttr(appEl, kAXMainWindowAttribute),
           CFGetTypeID(main as CFTypeRef) == AXUIElementGetTypeID()
        {
            return main as! AXUIElement
        }
        return windows[0]
    }

    static func locate(pid: pid_t, windowFilter: String?, axPath: String) throws -> AXUIElement {
        let root = try selectWindow(pid: pid, windowFilter: windowFilter)
        let rootSeg = pathSegment(
            role: copyAttr(root, kAXRoleAttribute) as? String,
            title: copyAttr(root, kAXTitleAttribute) as? String,
            identifier: copyAttr(root, kAXIdentifierAttribute) as? String)
        let rootPath = "/\(rootSeg)"
        if let hit = search(root, path: rootPath, target: axPath) {
            return hit
        }
        throw KageteError.notFound("No AX element matches path \(axPath).")
    }

    private static func search(_ el: AXUIElement, path: String, target: String) -> AXUIElement? {
        if path == target { return el }
        // Prune: if target doesn't start with current path, subtree cannot contain it.
        if !target.hasPrefix(path + "/") { return nil }

        guard let kids = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement], !kids.isEmpty else {
            return nil
        }
        let rawSegments: [String] = kids.map { child in
            pathSegment(
                role: copyAttr(child, kAXRoleAttribute) as? String,
                title: copyAttr(child, kAXTitleAttribute) as? String,
                identifier: copyAttr(child, kAXIdentifierAttribute) as? String)
        }
        var counts: [String: Int] = [:]
        for seg in rawSegments { counts[seg, default: 0] += 1 }
        var nextIndex: [String: Int] = [:]
        for (i, child) in kids.enumerated() {
            let base = rawSegments[i]
            let seg: String
            if (counts[base] ?? 0) > 1 {
                let k = nextIndex[base, default: 0]
                seg = "\(base)[\(k)]"
                nextIndex[base] = k + 1
            } else {
                seg = base
            }
            if let hit = search(child, path: "\(path)/\(seg)", target: target) {
                return hit
            }
        }
        return nil
    }

    static func screenCenter(of el: AXUIElement) -> CGPoint? {
        guard let bounds = frameOf(el) else { return nil }
        return CGPoint(x: bounds.x + bounds.width / 2.0, y: bounds.y + bounds.height / 2.0)
    }

    static func performAction(_ el: AXUIElement, action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }
}
