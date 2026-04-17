import CoreGraphics
import Foundation

enum MouseButton: String, CaseIterable {
    case left, right, middle
    var cg: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }
    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

enum Input {
    static func click(at point: CGPoint, button: MouseButton = .left, count: Int = 1) throws {
        try ensureAccessibility()
        moveCursor(to: point)
        for i in 1...max(1, count) {
            if let down = CGEvent(
                mouseEventSource: nil,
                mouseType: button.downType,
                mouseCursorPosition: point,
                mouseButton: button.cg)
            {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(
                mouseEventSource: nil,
                mouseType: button.upType,
                mouseCursorPosition: point,
                mouseButton: button.cg)
            {
                up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                up.post(tap: .cghidEventTap)
            }
        }
    }

    static func scroll(dx: Int32, dy: Int32, lines: Bool = true) throws {
        try ensureAccessibility()
        let unit: CGScrollEventUnit = lines ? .line : .pixel
        if let ev = CGEvent(
            scrollWheelEvent2Source: nil,
            units: unit,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0)
        {
            ev.post(tap: .cghidEventTap)
        }
    }

    static func type(_ text: String) throws {
        try ensureAccessibility()
        for scalar in text.unicodeScalars {
            let s = String(scalar)
            let utf16 = Array(s.utf16)
            guard
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { continue }
            utf16.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                    up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                }
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func key(_ combo: KeyCombo) throws {
        try ensureAccessibility()
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: false)
        else {
            throw KageteError.failure("Failed to create keyboard event.")
        }
        down.flags = combo.flags
        up.flags = combo.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func moveCursor(to point: CGPoint) {
        if let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left)
        {
            move.post(tap: .cghidEventTap)
        }
    }

    private static func ensureAccessibility() throws {
        guard Permissions.accessibility else {
            throw KageteError.notTrusted(
                "Accessibility permission required to post input events. Run `kagete doctor --prompt`.")
        }
    }
}
