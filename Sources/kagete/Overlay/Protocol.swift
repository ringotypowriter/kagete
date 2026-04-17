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
    static let idleTimeout: TimeInterval = 15.0
    /// How long each action pulse is visible.
    static let pulseDuration: TimeInterval = 0.4
    /// Duration of the "✓ control returned" ceremony before the daemon exits.
    static let releaseDuration: TimeInterval = 1.5

    /// Debug and release builds use different socket paths and brand labels so
    /// a locally-built kagete never collides with the installed release binary
    /// — each spawns and talks to its own daemon.
    #if DEBUG
    static let flavor = "dev"
    #else
    static let flavor = "release"
    #endif

    static var socketPath: String {
        let uid = getuid()
        let suffix = flavor == "release" ? "" : "-\(flavor)"
        return "/tmp/kagete-\(uid)-overlay\(suffix).sock"
    }

    /// Brand label shown on the overlay pill. Defaults to `"kagete"` for
    /// release builds and `"kagete-dev"` for debug builds so you can tell at
    /// a glance which binary drew the pill. Override with
    /// `KAGETE_OVERLAY_LABEL=MyAgent`.
    static var brandLabel: String {
        if let v = ProcessInfo.processInfo.environment["KAGETE_OVERLAY_LABEL"], !v.isEmpty {
            return v
        }
        return flavor == "release" ? "kagete" : "kagete-dev"
    }
}
