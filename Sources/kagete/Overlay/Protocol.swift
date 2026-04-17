import Foundation

/// IPC messages between kagete CLI clients and the overlay daemon. Framed
/// as single JSON objects terminated by `\n`.
enum OverlayMessage: Codable, Equatable, Sendable {
    case pulse(PulsePayload)
    case release(label: String)
    case status
    case stop

    struct PulsePayload: Codable, Equatable, Sendable {
        /// Screen-space action point, if the action has one (click/drag/scroll).
        /// `nil` for `type`/`key` which act on the focused element.
        var at: PointJSON?
        /// Short label shown on the pill ("click", "type", "drag", etc.).
        var label: String
        /// Target app name, if known.
        var app: String?
    }
}

struct PointJSON: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

enum OverlayConfig {
    /// Idle duration before the daemon self-retires and returns control to user.
    static let idleTimeout: TimeInterval = 10.0
    /// How long each action pulse is visible.
    static let pulseDuration: TimeInterval = 0.4
    /// Duration of the "✓ control returned" ceremony before the daemon exits.
    static let releaseDuration: TimeInterval = 1.5

    static var socketPath: String {
        let uid = getuid()
        return "/tmp/kagete-\(uid)-overlay.sock"
    }
}
