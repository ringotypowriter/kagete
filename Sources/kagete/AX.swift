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
    let actions: [String]?
    let frame: BoundsJSON?
    let axPath: String
    let children: [AXNode]

    /// A node carries information if it has any human-readable label or can be
    /// acted on directly via the AX API. Everything else is structural noise.
    var hasContent: Bool {
        let nonEmpty: (String?) -> Bool = { ($0?.isEmpty == false) }
        if nonEmpty(title) || nonEmpty(value) || nonEmpty(description)
            || nonEmpty(identifier) || nonEmpty(help) { return true }
        if let acts = actions, !acts.isEmpty { return true }
        return false
    }
}

enum AXInspector {
    static func inspect(
        pid: pid_t, windowFilter: String?, maxDepth: Int,
        compact: Bool = true, withActions: Bool = false
    ) throws -> AXNode {
        let chosen = try selectWindow(pid: pid, windowFilter: windowFilter)
        let rootSegment = pathSegment(
            role: copyAttr(chosen, kAXRoleAttribute) as? String,
            title: copyAttr(chosen, kAXTitleAttribute) as? String,
            identifier: copyAttr(chosen, kAXIdentifierAttribute) as? String)
        let raw = walk(
            chosen, path: "/\(rootSegment)", depth: 0,
            maxDepth: maxDepth, withActions: withActions)
        return compact ? prune(raw) ?? raw : raw
    }

    /// Strip structural noise: nodes with no label, no actions, and no labeled
    /// descendants. The surviving tree keeps its original axPath strings so
    /// `find`/`click` still resolve against the live tree unchanged.
    static func prune(_ node: AXNode) -> AXNode? {
        let kept = node.children.compactMap(prune)
        if node.hasContent || !kept.isEmpty {
            return AXNode(
                role: node.role, subrole: node.subrole,
                title: node.title, value: node.value,
                description: node.description, identifier: node.identifier,
                help: node.help, enabled: node.enabled, focused: node.focused,
                actions: node.actions, frame: node.frame,
                axPath: node.axPath, children: kept)
        }
        return nil
    }

    private static func walk(
        _ el: AXUIElement, path: String, depth: Int, maxDepth: Int,
        withActions: Bool
    ) -> AXNode {
        let role = copyAttr(el, kAXRoleAttribute) as? String
        let subrole = copyAttr(el, kAXSubroleAttribute) as? String
        let title = copyAttr(el, kAXTitleAttribute) as? String
        let value = stringify(copyAttr(el, kAXValueAttribute))
        let description = copyAttr(el, kAXDescriptionAttribute) as? String
        let identifier = copyAttr(el, kAXIdentifierAttribute) as? String
        let help = copyAttr(el, kAXHelpAttribute) as? String
        let enabled = copyAttr(el, kAXEnabledAttribute) as? Bool
        let focused = copyAttr(el, kAXFocusedAttribute) as? Bool
        let actions = withActions ? actionNames(el) : []
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
                children.append(walk(
                    child, path: "\(path)/\(seg)", depth: depth + 1,
                    maxDepth: maxDepth, withActions: withActions))
            }
        }

        return AXNode(
            role: role, subrole: subrole, title: title, value: value,
            description: description, identifier: identifier, help: help,
            enabled: enabled, focused: focused,
            actions: actions.isEmpty ? nil : actions,
            frame: frame,
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

    /// Names of the AX actions an element advertises (e.g. `AXPress`,
    /// `AXShowMenu`, `AXIncrement`). Empty array when the API call fails or
    /// the element has no actions — callers should treat both the same.
    static func actionNames(_ el: AXUIElement) -> [String] {
        var ref: CFArray?
        guard AXUIElementCopyActionNames(el, &ref) == .success,
              let array = ref as? [String]
        else { return [] }
        return array
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

    static func find(
        pid: pid_t,
        windowFilter: String?,
        criteria: FindCriteria,
        limit: Int,
        maxDepth: Int
    ) throws -> [AXHit] {
        let root = try selectWindow(pid: pid, windowFilter: windowFilter)
        let rootSeg = pathSegment(
            role: copyAttr(root, kAXRoleAttribute) as? String,
            title: copyAttr(root, kAXTitleAttribute) as? String,
            identifier: copyAttr(root, kAXIdentifierAttribute) as? String)

        var hits: [AXHit] = []
        _ = traverse(root, path: "/\(rootSeg)", depth: 0, maxDepth: maxDepth) { el, path in
            if matches(el, criteria: criteria) {
                hits.append(hit(from: el, path: path))
                if hits.count >= limit { return false }
            }
            return true
        }
        return hits
    }

    /// Pre-order DFS with stable sibling-indexed paths. Visitor returns
    /// `false` to stop traversal entirely.
    @discardableResult
    private static func traverse(
        _ el: AXUIElement,
        path: String,
        depth: Int,
        maxDepth: Int,
        visit: (AXUIElement, String) -> Bool
    ) -> Bool {
        if !visit(el, path) { return false }
        if depth >= maxDepth { return true }
        guard let kids = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement], !kids.isEmpty else {
            return true
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
            if !traverse(child, path: "\(path)/\(seg)", depth: depth + 1, maxDepth: maxDepth, visit: visit) {
                return false
            }
        }
        return true
    }

    private static func matches(_ el: AXUIElement, criteria: FindCriteria) -> Bool {
        let role = copyAttr(el, kAXRoleAttribute) as? String
        let subrole = copyAttr(el, kAXSubroleAttribute) as? String
        let title = (copyAttr(el, kAXTitleAttribute) as? String) ?? ""
        let identifier = copyAttr(el, kAXIdentifierAttribute) as? String
        let description = (copyAttr(el, kAXDescriptionAttribute) as? String) ?? ""
        let value = stringify(copyAttr(el, kAXValueAttribute)) ?? ""
        let enabled = copyAttr(el, kAXEnabledAttribute) as? Bool

        if let want = criteria.role, role != want { return false }
        if let want = criteria.subrole, subrole != want { return false }
        if let want = criteria.title, title != want { return false }
        if let want = criteria.titleContains,
           !title.localizedCaseInsensitiveContains(want) { return false }
        if let want = criteria.identifier, identifier != want { return false }
        if let want = criteria.descriptionContains,
           !description.localizedCaseInsensitiveContains(want) { return false }
        if let want = criteria.valueContains,
           !value.localizedCaseInsensitiveContains(want) { return false }
        if criteria.enabledOnly, enabled != true { return false }
        if criteria.disabledOnly, enabled == true { return false }
        return true
    }

    private static func hit(from el: AXUIElement, path: String) -> AXHit {
        let acts = actionNames(el)
        return AXHit(
            role: copyAttr(el, kAXRoleAttribute) as? String,
            subrole: copyAttr(el, kAXSubroleAttribute) as? String,
            title: copyAttr(el, kAXTitleAttribute) as? String,
            value: stringify(copyAttr(el, kAXValueAttribute)),
            description: copyAttr(el, kAXDescriptionAttribute) as? String,
            identifier: copyAttr(el, kAXIdentifierAttribute) as? String,
            enabled: copyAttr(el, kAXEnabledAttribute) as? Bool,
            focused: copyAttr(el, kAXFocusedAttribute) as? Bool,
            actions: acts.isEmpty ? nil : acts,
            frame: frameOf(el),
            axPath: path)
    }
}

struct AXHit: Codable {
    let role: String?
    let subrole: String?
    let title: String?
    let value: String?
    let description: String?
    let identifier: String?
    let enabled: Bool?
    let focused: Bool?
    let actions: [String]?
    let frame: BoundsJSON?
    let axPath: String
}

struct FindCriteria: Equatable {
    var role: String?
    var subrole: String?
    var title: String?
    var titleContains: String?
    var identifier: String?
    var descriptionContains: String?
    var valueContains: String?
    var enabledOnly: Bool = false
    var disabledOnly: Bool = false

    var hasAnyFilter: Bool {
        role != nil || subrole != nil || title != nil || titleContains != nil
            || identifier != nil || descriptionContains != nil || valueContains != nil
            || enabledOnly || disabledOnly
    }
}
