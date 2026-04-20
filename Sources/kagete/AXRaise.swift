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

        var changedFocus: Bool {
            setFrontmost || raisedWindow || setMain
        }
    }

    @discardableResult
    static func raise(pid: pid_t, windowFilter: String?) throws -> Report {
        guard Permissions.accessibility else {
            throw KageteError.notTrusted(
                "Accessibility permission not granted. Run `kagete doctor --prompt`, or grant it to \"\(Permissions.hostLabel)\" (the process that launched kagete, not kagete itself) in System Settings → Privacy & Security → Accessibility.")
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

/// Explicit activation dispatcher. The agent picks the method at the CLI
/// level via `kagete activate --method app|ax|both`; there is no `.auto`
/// fallback — fallback decisions belong to the agent, not the binary.
///
/// - `app`  — classic `NSRunningApplication.activate()`
/// - `ax`   — AX frontmost + window raise (different code path, bypasses
///            the macOS 14 activation-token broker; useful when floating
///            panels like CleanShot X contest the default path)
/// - `both` — AX raise first, then `app.activate()`
enum Activator {
    enum Method: String { case ax, app, both }

    /// Perform the chosen activation sequence. Always followed by a 300 ms
    /// settle window — long enough for Electron / Chromium-backed apps to
    /// finish their JS-side activation handlers before the next command
    /// reads AX state.
    static func activateExplicit(_ target: ResolvedTarget, method: Method) async throws {
        switch method {
        case .app:
            target.app.activate()
        case .ax:
            _ = try AXRaise.raise(pid: target.pid, windowFilter: target.windowFilter)
        case .both:
            _ = try AXRaise.raise(pid: target.pid, windowFilter: target.windowFilter)
            target.app.activate()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}
