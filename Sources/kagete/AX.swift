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
        let rootBundle = bundle(for: chosen)
        let rootSegment = pathSegment(
            role: rootBundle.role, title: rootBundle.title,
            identifier: rootBundle.identifier)
        let raw = walk(
            chosen, bundle: rootBundle,
            path: "/\(rootSegment)", depth: 0,
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
        _ el: AXUIElement, bundle b: AXBundle,
        path: String, depth: Int, maxDepth: Int,
        withActions: Bool
    ) -> AXNode {
        let actions = withActions ? actionNames(el) : []

        var children: [AXNode] = []
        if depth < maxDepth, !b.children.isEmpty {
            let kids = b.children
            let childBundles = kids.map { AXInspector.bundle(for: $0) }
            let rawSegments: [String] = childBundles.map { cb in
                pathSegment(role: cb.role, title: cb.title, identifier: cb.identifier)
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
                    child, bundle: childBundles[i],
                    path: "\(path)/\(seg)", depth: depth + 1,
                    maxDepth: maxDepth, withActions: withActions))
            }
        }

        return AXNode(
            role: b.role, subrole: b.subrole, title: b.title, value: b.valueString,
            description: b.description, identifier: b.identifier, help: b.help,
            enabled: b.enabled, focused: b.focused,
            actions: actions.isEmpty ? nil : actions,
            frame: b.frame,
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

    /// Batch fetch of the 12 attributes kagete cares about for tree walks.
    /// One IPC per element instead of ~14 individual `copyAttr` calls.
    /// Missing attributes come back as `AXValue` error wrappers and are
    /// surfaced as `nil` here.
    private nonisolated(unsafe) static let bundleKeys: [CFString] = [
        kAXRoleAttribute as CFString,
        kAXSubroleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXIdentifierAttribute as CFString,
        kAXHelpAttribute as CFString,
        kAXEnabledAttribute as CFString,
        kAXFocusedAttribute as CFString,
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString,
        kAXChildrenAttribute as CFString,
    ]

    static func bundle(for el: AXUIElement) -> AXBundle {
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            el, bundleKeys as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        let raw: [Any] = (err == .success ? (out as? [Any]) : nil) ?? []

        func at(_ i: Int) -> Any? {
            guard i < raw.count else { return nil }
            let v = raw[i]
            // Apple wraps "attribute not applicable" as AXValue of type axError.
            if CFGetTypeID(v as CFTypeRef) == AXValueGetTypeID() {
                if AXValueGetType(v as! AXValue) == .axError { return nil }
            }
            return v
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        var frame: BoundsJSON? = nil
        if let p = at(9), CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID(),
           let s = at(10), CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID(),
           AXValueGetValue(p as! AXValue, .cgPoint, &position),
           AXValueGetValue(s as! AXValue, .cgSize, &size)
        {
            frame = BoundsJSON(CGRect(origin: position, size: size))
        }

        return AXBundle(
            role: at(0) as? String,
            subrole: at(1) as? String,
            title: at(2) as? String,
            valueString: stringify(at(3)),
            description: at(4) as? String,
            identifier: at(5) as? String,
            help: at(6) as? String,
            enabled: (at(7) as? NSNumber)?.boolValue,
            focused: (at(8) as? NSNumber)?.boolValue,
            frame: frame,
            children: (at(11) as? [AXUIElement]) ?? [])
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
                "Accessibility permission not granted. Run `kagete doctor --prompt`, or grant it to \"\(Permissions.hostLabel)\" (the process that launched kagete — not kagete itself) in System Settings → Privacy & Security → Accessibility.")
        }
        let appEl = AXUIElementCreateApplication(pid)
        // Cap AX IPC at 1.5s per call. Default is ~6s, which lets one stuck
        // web frame stall an entire tree walk. Set on the app element and
        // it cascades to all child elements from this app.
        AXUIElementSetMessagingTimeout(appEl, 1.5)
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
        let rootBundle = bundle(for: root)
        let rootSeg = pathSegment(
            role: rootBundle.role, title: rootBundle.title,
            identifier: rootBundle.identifier)
        let rootPath = "/\(rootSeg)"
        if let hit = search(root, bundle: rootBundle, path: rootPath, target: axPath) {
            return hit
        }
        throw KageteError.notFound("No AX element matches path \(axPath).")
    }

    private static func search(
        _ el: AXUIElement, bundle b: AXBundle, path: String, target: String
    ) -> AXUIElement? {
        if path == target { return el }
        // Prune: if target doesn't start with current path, subtree cannot contain it.
        if !target.hasPrefix(path + "/") { return nil }

        let kids = b.children
        guard !kids.isEmpty else { return nil }
        let childBundles = kids.map { AXInspector.bundle(for: $0) }
        let rawSegments: [String] = childBundles.map { cb in
            pathSegment(role: cb.role, title: cb.title, identifier: cb.identifier)
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
            if let hit = search(
                child, bundle: childBundles[i],
                path: "\(path)/\(seg)", target: target)
            {
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

    /// Read the app's AXFocusedUIElement and reconstruct its role/title for a
    /// post-action `verify` block. Best-effort — returns nil if AX says no
    /// element is focused (common for apps whose main window is unfocused).
    static func focusedSummary(pid: pid_t) -> (role: String?, title: String?)? {
        let appEl = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appEl, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let ref = focused else { return nil }
        let el = ref as! AXUIElement
        let b = bundle(for: el)
        return (b.role, b.title)
    }

    /// Fuller snapshot of the focused element — used by `screenshot` to
    /// draw a visual focus indicator and by `type` to diff values
    /// pre/post typing. Keeps the raw `AXUIElement` so callers can read
    /// attributes on the same instance later (focus may have moved by
    /// the time they look again).
    struct FocusSnapshot {
        let element: AXUIElement
        let role: String?
        let title: String?
        let value: String?
        let frame: CGRect?
    }

    static func focusedSnapshot(pid: pid_t) -> FocusSnapshot? {
        let appEl = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appEl, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let ref = focused else { return nil }
        let el = ref as! AXUIElement
        let b = bundle(for: el)
        let frame = b.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return FocusSnapshot(
            element: el, role: b.role, title: b.title,
            value: b.valueString, frame: frame)
    }

    /// Re-read the current `AXValue` of an element. Used by `type` to
    /// confirm that typed text actually landed in the target — the only
    /// reliable signal, since `AXFocusedUIElement` may have moved
    /// during typing (form submit, autocomplete, etc).
    static func currentValue(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            el, kAXValueAttribute as CFString, &ref) == .success,
              let raw = ref
        else { return nil }
        return stringify(raw)
    }

    /// AX roles that genuinely accept keyboard input. Used to decide whether
    /// `type`'s auto-focus pass needs to fire — if the app already has one
    /// of these focused, the click did its job and we leave focus alone.
    private static let textInputRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField",
        "AXComboBox", "AXTextInput",
    ]

    /// Best-effort: ensure a text input has keyboard focus before `type`.
    /// Two-tier heuristic — many UIs don't install first responder on
    /// synthesized clicks (custom NSViews) or on shortcut-opened search
    /// bars (Electron, QQ音乐), so `type` would otherwise spray keys
    /// into the void:
    ///   1. If app focus is already on a known text input → no-op.
    ///   2. Walk the focused window for visible+enabled text inputs.
    ///      Prefer one whose frame contains the cursor (click-then-type
    ///      — handles forms with multiple inputs). Else pick the topmost
    ///      (shortcut-then-type — search/URL bars cluster at top).
    ///   3. Fallback: AX hit-test at the cursor (catches custom-drawn
    ///      inputs whose role doesn't surface in the window walk).
    /// All writes use `AXUIElementSetAttributeValue(kAXFocusedAttribute)`.
    /// Web inputs focus via DOM, not AX, so this won't help embedded
    /// web content — but won't hurt either.
    @discardableResult
    static func ensureTextFocus(pid: pid_t) -> Bool {
        if let cur = focusedSummary(pid: pid),
           let role = cur.role, textInputRoles.contains(role)
        {
            return true
        }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let candidates = textInputsInFocusedWindow(pid: pid)
        if !candidates.isEmpty {
            let target = pickInput(candidates: candidates, cursor: cursor)
            if AXUIElementSetAttributeValue(
                target, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            {
                return true
            }
        }
        let appEl = AXUIElementCreateApplication(pid)
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            appEl, Float(cursor.x), Float(cursor.y), &hit)
        guard err == .success, let el = hit else { return false }
        return AXUIElementSetAttributeValue(
            el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appEl, kAXFocusedWindowAttribute as CFString, &ref)
        guard err == .success, let raw = ref else { return nil }
        return (raw as! AXUIElement)
    }

    private static func textInputsInFocusedWindow(
        pid: pid_t, maxDepth: Int = 32
    ) -> [(el: AXUIElement, frame: CGRect)] {
        guard let window = focusedWindow(pid: pid) else { return [] }
        let rootBundle = bundle(for: window)
        var hits: [(AXUIElement, CGRect)] = []
        _ = traverse(
            window, bundle: rootBundle, path: "",
            depth: 0, maxDepth: maxDepth
        ) { el, b, _ in
            guard let role = b.role, textInputRoles.contains(role) else { return true }
            if b.enabled == false { return true }
            guard let f = b.frame, f.width > 0, f.height > 0 else { return true }
            hits.append((el, CGRect(x: f.x, y: f.y, width: f.width, height: f.height)))
            return true
        }
        return hits
    }

    private static func pickInput(
        candidates: [(el: AXUIElement, frame: CGRect)], cursor: CGPoint
    ) -> AXUIElement {
        if let under = candidates.first(where: { $0.frame.contains(cursor) }) {
            return under.el
        }
        return candidates.min(by: { $0.frame.minY < $1.frame.minY })!.el
    }

    /// Compact overview of a window's AX tree — designed so agents can decide
    /// whether to drill in via `find` or ask for the full tree via
    /// `inspect --tree`. Avoids dumping tens of thousands of nodes by default.
    static func summarize(
        pid: pid_t, windowFilter: String?, maxDepth: Int,
        actionableSampleLimit: Int = 20
    ) throws -> InspectSummary {
        let chosen = try selectWindow(pid: pid, windowFilter: windowFilter)
        let rootBundle = bundle(for: chosen)
        let rootSeg = pathSegment(
            role: rootBundle.role, title: rootBundle.title,
            identifier: rootBundle.identifier)

        var total = 0
        var withContent = 0
        var roleHist: [String: Int] = [:]
        var actionable: [ActionableSample] = []

        _ = traverse(
            chosen, bundle: rootBundle, path: "/\(rootSeg)",
            depth: 0, maxDepth: maxDepth
        ) { el, b, path in
            total += 1
            if let r = b.role { roleHist[r, default: 0] += 1 }
            let contentful: (String?) -> Bool = { ($0?.isEmpty == false) }
            if contentful(b.title) || contentful(b.valueString) || contentful(b.description)
                || contentful(b.identifier) { withContent += 1 }
            if actionable.count < actionableSampleLimit {
                let acts = actionNames(el)
                if acts.contains(kAXPressAction) || acts.contains(kAXIncrementAction)
                    || acts.contains(kAXDecrementAction)
                {
                    actionable.append(ActionableSample(
                        axPath: path, role: b.role, title: b.title,
                        actions: acts))
                }
            }
            return true
        }

        let focusedAxPath: String? = nil

        return InspectSummary(
            window: InspectSummary.WindowInfo(
                title: rootBundle.title, role: rootBundle.role,
                frame: rootBundle.frame),
            totalNodes: total,
            nodesWithContent: withContent,
            roleHistogram: roleHist,
            actionableCount: actionable.count,
            actionableSample: actionable,
            focusedAxPath: focusedAxPath)
    }

    static func find(
        pid: pid_t,
        windowFilter: String?,
        criteria: FindCriteria,
        limit: Int,
        maxDepth: Int
    ) throws -> [AXHit] {
        let root = try selectWindow(pid: pid, windowFilter: windowFilter)
        let rootBundle = bundle(for: root)
        let rootSeg = pathSegment(
            role: rootBundle.role, title: rootBundle.title,
            identifier: rootBundle.identifier)

        var hits: [AXHit] = []
        _ = traverse(root, bundle: rootBundle, path: "/\(rootSeg)", depth: 0, maxDepth: maxDepth) { el, b, path in
            if matches(bundle: b, criteria: criteria) {
                hits.append(hit(from: el, bundle: b, path: path))
                if hits.count >= limit { return false }
            }
            return true
        }
        return hits
    }

    /// Pre-order DFS with stable sibling-indexed paths. Visitor receives the
    /// pre-fetched bundle so filtering/materializing hits costs zero IPC.
    /// Returning `false` stops traversal entirely.
    @discardableResult
    private static func traverse(
        _ el: AXUIElement,
        bundle b: AXBundle,
        path: String,
        depth: Int,
        maxDepth: Int,
        visit: (AXUIElement, AXBundle, String) -> Bool
    ) -> Bool {
        if !visit(el, b, path) { return false }
        if depth >= maxDepth { return true }
        let kids = b.children
        guard !kids.isEmpty else { return true }
        let childBundles = kids.map { AXInspector.bundle(for: $0) }
        let rawSegments: [String] = childBundles.map { cb in
            pathSegment(role: cb.role, title: cb.title, identifier: cb.identifier)
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
            if !traverse(
                child, bundle: childBundles[i],
                path: "\(path)/\(seg)", depth: depth + 1,
                maxDepth: maxDepth, visit: visit)
            {
                return false
            }
        }
        return true
    }

    private static func matches(bundle b: AXBundle, criteria: FindCriteria) -> Bool {
        if let want = criteria.role, b.role != want { return false }
        if let want = criteria.subrole, b.subrole != want { return false }
        let title = b.title ?? ""
        let description = b.description ?? ""
        let value = b.valueString ?? ""
        if let want = criteria.title, title != want { return false }
        if let want = criteria.titleContains,
           !title.localizedCaseInsensitiveContains(want) { return false }
        if let want = criteria.identifier, b.identifier != want { return false }
        if let want = criteria.descriptionContains,
           !description.localizedCaseInsensitiveContains(want) { return false }
        if let want = criteria.valueContains,
           !value.localizedCaseInsensitiveContains(want) { return false }
        if criteria.enabledOnly, b.enabled != true { return false }
        if criteria.disabledOnly, b.enabled == true { return false }
        return true
    }

    private static func hit(from el: AXUIElement, bundle b: AXBundle, path: String) -> AXHit {
        let acts = actionNames(el)
        return AXHit(
            role: b.role, subrole: b.subrole,
            title: b.title, value: b.valueString,
            description: b.description, identifier: b.identifier,
            enabled: b.enabled, focused: b.focused,
            actions: acts.isEmpty ? nil : acts,
            frame: b.frame,
            axPath: path)
    }
}

struct ActionableSample: Codable {
    let axPath: String
    let role: String?
    let title: String?
    let actions: [String]
}

struct InspectSummary: Codable {
    let window: WindowInfo
    let totalNodes: Int
    let nodesWithContent: Int
    let roleHistogram: [String: Int]
    let actionableCount: Int
    let actionableSample: [ActionableSample]
    let focusedAxPath: String?

    struct WindowInfo: Codable {
        let title: String?
        let role: String?
        let frame: BoundsJSON?
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

struct AXBundle {
    let role: String?
    let subrole: String?
    let title: String?
    let valueString: String?
    let description: String?
    let identifier: String?
    let help: String?
    let enabled: Bool?
    let focused: Bool?
    let frame: BoundsJSON?
    let children: [AXUIElement]
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
