import AppKit
import ApplicationServices
import Foundation

/// AX-level window raise — bypasses the window-server activation broker.
///
/// `NSRunningApplication.activate()` routes through the activation-token
/// system introduced in macOS 14. Tools that hold high-level floating
/// panels (CleanShot X recorder, QuickTime, Zoom share toolbar) can
/// contest that path, leaving the target app briefly raised but unable
/// to hold keyboard focus. Going through the AX API uses a different
/// code path and is what most computer-use tools rely on.
enum AXRaise {
    struct Report {
        let setFrontmost: Bool
        let raisedWindow: Bool
        let setMain: Bool
        let frontmostAfter: String?
    }

    @discardableResult
    static func raise(pid: pid_t, windowFilter: String?) throws -> Report {
        guard Permissions.accessibility else {
            throw KageteError.notTrusted(
                "Accessibility permission not granted. Run `kagete doctor --prompt`.")
        }

        let appEl = AXUIElementCreateApplication(pid)
        let window = try AXInspector.selectWindow(pid: pid, windowFilter: windowFilter)

        let setFrontmost = AXUIElementSetAttributeValue(
            appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success

        let raised = AXUIElementPerformAction(
            window, kAXRaiseAction as CFString) == .success

        let setMain = AXUIElementSetAttributeValue(
            window, kAXMainAttribute as CFString, kCFBooleanTrue) == .success

        // Let the window server settle before anyone reads frontmost.
        usleep(80_000)

        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName

        return Report(
            setFrontmost: setFrontmost,
            raisedWindow: raised,
            setMain: setMain,
            frontmostAfter: frontmost)
    }
}

/// Picks between AX-raise and `NSRunningApplication.activate()` at runtime.
///
/// `KAGETE_RAISE` env var:
/// - `ax`   — AX frontmost + window raise only
/// - `app`  — classic `NSRunningApplication.activate()` only (today's default)
/// - `both` — try AX raise first, then `app.activate()` as a fallback
/// - unset / anything else → `app` (unchanged default behavior)
enum Activator {
    enum Method: String { case ax, app, both }

    static var method: Method {
        let raw = ProcessInfo.processInfo.environment["KAGETE_RAISE"]?.lowercased() ?? ""
        return Method(rawValue: raw) ?? .app
    }

    static func activate(_ target: ResolvedTarget) async throws {
        switch method {
        case .app:
            target.app.activate()
        case .ax:
            _ = try AXRaise.raise(pid: target.pid, windowFilter: target.windowFilter)
        case .both:
            _ = try AXRaise.raise(pid: target.pid, windowFilter: target.windowFilter)
            target.app.activate()
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }
}
