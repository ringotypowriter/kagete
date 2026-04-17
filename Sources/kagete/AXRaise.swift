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
/// - `auto` — AX frontmost + window raise first, fall back to `app.activate()` if needed
/// - `ax`   — AX frontmost + window raise only
/// - `app`  — classic `NSRunningApplication.activate()` only
/// - `both` — always do both: AX raise first, then `app.activate()`
/// - unset / anything else → `auto`
enum Activator {
    enum Method: String { case auto, ax, app, both }

    static var method: Method {
        method(for: ProcessInfo.processInfo.environment["KAGETE_RAISE"])
    }

    static func method(for rawValue: String?) -> Method {
        Method(rawValue: rawValue?.lowercased() ?? "") ?? .auto
    }

    static func activate(_ target: ResolvedTarget) async throws {
        switch method {
        case .auto:
            if !autoRaise(target) {
                target.app.activate()
            }
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

    private static func autoRaise(_ target: ResolvedTarget) -> Bool {
        do {
            let report = try AXRaise.raise(pid: target.pid, windowFilter: target.windowFilter)
            return report.changedFocus
        } catch let error as KageteError {
            switch error {
            case .notTrusted, .notFound, .ambiguous, .invalidArgument, .failure:
                return false
            }
        } catch {
            return false
        }
    }
}
