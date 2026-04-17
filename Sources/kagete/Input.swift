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
    /// Minimum gap (µs) between successive posted events. HID drops events
    /// that arrive faster than the event tap can drain them — especially
    /// keyboard events with Unicode payloads. 3ms is empirically enough.
    static let interEventDelayMicros: UInt32 = 3_000

    /// Gap between distinct clicks (µs). Some apps, especially custom
    /// web-backed views, miss "machine-gun" double-clicks that arrive too
    /// quickly even if the click-state increments correctly. 180 ms stays
    /// comfortably within the normal macOS double-click window while matching
    /// a more human cadence.
    static let interClickDelayMicros: UInt32 = 180_000

    static func click(at point: CGPoint, button: MouseButton = .left, count: Int = 1) throws {
        try ensureAccessibility()
        let source = try makeEventSource()
        // Detach cursor from the real mouse and warp to the exact target
        // before any synthesis. Without this, mouseMoved posted at
        // .cghidEventTap goes through pointer acceleration — a real mouse
        // delta concurrent with our synthesis can shift the landing site
        // by hundreds of points. `CGWarpMouseCursorPosition` bypasses
        // acceleration entirely; the reassociate in `defer` hands the
        // cursor back to the user immediately after.
        CGAssociateMouseAndMouseCursorPosition(0)
        defer { CGAssociateMouseAndMouseCursorPosition(1) }
        CGWarpMouseCursorPosition(point)

        moveCursor(to: point, source: source)
        usleep(interEventDelayMicros)

        let clicks = max(1, count)
        let firstEventNumber = Int64(CGEventSource.counterForEventType(
            .hidSystemState,
            eventType: button.downType)) + 1
        for click in 1...clicks {
            let eventNumber = firstEventNumber + Int64(click - 1)
            if let down = Self.makeMouseClickEvent(
                source: source,
                type: button.downType,
                point: point,
                button: button,
                clickState: click,
                eventNumber: eventNumber,
                pressure: 1)
            {
                down.post(tap: .cghidEventTap)
            }
            usleep(interEventDelayMicros)

            if let up = Self.makeMouseClickEvent(
                source: source,
                type: button.upType,
                point: point,
                button: button,
                clickState: click,
                eventNumber: eventNumber,
                pressure: 0)
            {
                up.post(tap: .cghidEventTap)
            }

            // Only pause *between* clicks — sleeping after the final up
            // is wasteful and slows down the caller for no benefit.
            if click < clicks {
                usleep(interClickDelayMicros)
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
            usleep(interEventDelayMicros)
            up.post(tap: .cghidEventTap)
            usleep(interEventDelayMicros)
        }
    }

    static func drag(
        from start: CGPoint,
        to end: CGPoint,
        steps: Int = 20,
        holdMicros: UInt32 = 0,
        modifiers: CGEventFlags = []
    ) throws {
        try ensureAccessibility()
        let source = try makeEventSource()
        // See `click` — warp + disassociate to neutralize pointer
        // acceleration for the duration of the synthesized drag.
        CGAssociateMouseAndMouseCursorPosition(0)
        defer { CGAssociateMouseAndMouseCursorPosition(1) }
        CGWarpMouseCursorPosition(start)

        moveCursor(to: start, source: source)
        usleep(interEventDelayMicros)

        if let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left)
        {
            down.flags = modifiers
            down.post(tap: .cghidEventTap)
        }
        if holdMicros > 0 { usleep(holdMicros) } else { usleep(interEventDelayMicros) }

        let n = max(1, steps)
        for i in 1...n {
            let t = Double(i) / Double(n)
            let p = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t)
            if let ev = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: p,
                mouseButton: .left)
            {
                ev.flags = modifiers
                ev.post(tap: .cghidEventTap)
            }
            usleep(interEventDelayMicros)
        }

        if let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left)
        {
            up.flags = modifiers
            up.post(tap: .cghidEventTap)
        }
        usleep(interEventDelayMicros)
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
        usleep(interEventDelayMicros)
        up.post(tap: .cghidEventTap)
        usleep(interEventDelayMicros)
    }

    static func makeEventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw KageteError.failure("Failed to create mouse event source.")
        }
        return source
    }

    static func makeMouseClickEvent(
        source: CGEventSource,
        type: CGEventType,
        point: CGPoint,
        button: MouseButton,
        clickState: Int,
        eventNumber: Int64,
        pressure: Double
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button.cg)
        else { return nil }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        return event
    }

    private static func moveCursor(to point: CGPoint, source: CGEventSource? = nil) {
        if let move = CGEvent(
            mouseEventSource: source,
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
