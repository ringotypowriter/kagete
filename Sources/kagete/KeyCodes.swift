import CoreGraphics
import Foundation

/// Combination of one base key plus modifier flags, produced from strings
/// like `"cmd+shift+s"` or `"return"` or `"f12"`.
struct KeyCombo: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum KeyCodes {
    /// Parse a human key combo like "cmd+shift+s" into virtual keycode + flags.
    /// Modifier aliases: cmd/command/meta, ctrl/control, opt/option/alt, shift, fn.
    /// Base keys: a-z, 0-9, named keys (return, tab, space, esc, delete, arrows, f1-f12, etc.).
    static func parse(_ combo: String) throws -> KeyCombo {
        let parts = combo
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !parts.isEmpty else {
            throw KageteError.invalidArgument("Empty key combo.")
        }

        var flags: CGEventFlags = []
        var base: String?
        for p in parts {
            if let mod = modifierFlag(p) {
                flags.insert(mod)
            } else {
                if base != nil {
                    throw KageteError.invalidArgument("Key combo has multiple base keys: \(combo).")
                }
                base = p
            }
        }
        guard let baseKey = base else {
            throw KageteError.invalidArgument("Key combo \(combo) has no base key.")
        }
        guard let code = keyCode(for: baseKey) else {
            throw KageteError.invalidArgument("Unknown key name: \(baseKey).")
        }
        return KeyCombo(keyCode: code, flags: flags)
    }

    /// Parse a plus-separated modifier string like "shift+cmd" into flags.
    /// Empty input → no flags.
    static func parseModifiers(_ combo: String) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        let parts = combo
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for p in parts where !p.isEmpty {
            guard let mod = modifierFlag(p) else {
                throw KageteError.invalidArgument("Unknown modifier: \(p).")
            }
            flags.insert(mod)
        }
        return flags
    }

    private static func modifierFlag(_ name: String) -> CGEventFlags? {
        switch name {
        case "cmd", "command", "meta": return .maskCommand
        case "ctrl", "control": return .maskControl
        case "opt", "option", "alt": return .maskAlternate
        case "shift": return .maskShift
        case "fn", "function": return .maskSecondaryFn
        default: return nil
        }
    }

    /// Maps a lowercased key name to its macOS virtual keycode (Carbon HIToolbox).
    static func keyCode(for name: String) -> CGKeyCode? {
        if let c = named[name] { return c }
        // Single-character letters / digits / punctuation shortcut.
        if name.count == 1, let c = named[name] { return c }
        return nil
    }

    private static let named: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, " ": 49,
        "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
        "forward-delete": 117, "forwarddelete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118,
        "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}
