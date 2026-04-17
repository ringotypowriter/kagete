import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

@main
struct Kagete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kagete",
        abstract: "Agent computer-use CLI for macOS: inspect windows, screenshot, click, type.",
        version: "0.1.0",
        subcommands: [
            Doctor.self,
            Windows.self,
            Inspect.self,
            Find.self,
            Screenshot.self,
            Click.self,
            TypeText.self,
            Key.self,
            Scroll.self,
            Drag.self,
            Release.self,
            Raise.self,
            Overlay.self,
            OverlayDaemonEntry.self,
        ]
    )
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check macOS permissions kagete needs (Accessibility, Screen Recording).")

    @Flag(name: .long, help: "Trigger the system permission prompts for any missing grants.")
    var prompt: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() async throws {
        if prompt {
            if !Permissions.accessibility { Permissions.promptAccessibility() }
            if !Permissions.screenRecording { Permissions.promptScreenRecording() }
        }

        let ax = Permissions.accessibility
        let sr = Permissions.screenRecording

        if json {
            struct Report: Codable { let accessibility: Bool; let screenRecording: Bool; let ok: Bool }
            try JSON.print(Report(accessibility: ax, screenRecording: sr, ok: ax && sr))
            return
        }

        print("kagete doctor")
        print("  Accessibility     : \(ax ? "granted" : "MISSING")")
        print("  Screen Recording  : \(sr ? "granted" : "MISSING")")
        if !ax {
            print("    → System Settings → Privacy & Security → Accessibility → add kagete.")
        }
        if !sr {
            print("    → System Settings → Privacy & Security → Screen Recording → add kagete.")
        }
        if ax && sr {
            print("\nAll good, leader. ✓")
        } else {
            print("\nFix the items above, or rerun with --prompt to trigger system dialogs.")
            throw ExitCode(1)
        }
    }
}

struct Windows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List on-screen windows as JSON.")

    @Option(name: .long, help: "Filter by app name (localized or executable).")
    var app: String?

    @Option(name: .long, help: "Filter by bundle identifier.")
    var bundle: String?

    @Option(name: .long, help: "Filter by process id.")
    var pid: Int32?

    func run() async throws {
        var records = WindowList.all()
        if let pid = pid { records = records.filter { $0.pid == pid } }
        if let app = app {
            let lo = app.lowercased()
            records = records.filter { ($0.app ?? "").lowercased() == lo }
        }
        if let bundle = bundle {
            records = records.filter { $0.bundleId == bundle }
        }
        try JSON.print(records)
    }
}

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Dump the AX element tree of a target window as JSON (compact by default).")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Maximum tree depth to descend.")
    var maxDepth: Int = 12

    @Flag(name: .long, help: "Emit the full raw tree without pruning unlabeled AXUnknown nodes.")
    var full: Bool = false

    @Flag(name: .long, help: "Include AX action names per node (extra IPC per element — slow on large trees).")
    var withActions: Bool = false

    func run() async throws {
        let resolved = try TargetResolver.resolve(target)
        let node = try AXInspector.inspect(
            pid: resolved.pid, windowFilter: resolved.windowFilter,
            maxDepth: maxDepth, compact: !full, withActions: withActions)
        try JSON.print(node)
    }
}

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Search the AX tree of a window for matching elements.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Exact AX role (e.g. AXButton, AXTextField).")
    var role: String?

    @Option(name: .long, help: "Exact AX subrole (e.g. AXCloseButton).")
    var subrole: String?

    @Option(name: .long, help: "Exact title match.")
    var title: String?

    @Option(name: .long, help: "Substring of title (case-insensitive).")
    var titleContains: String?

    @Option(name: [.customLong("id"), .customLong("identifier")], help: "Exact AXIdentifier.")
    var identifier: String?

    @Option(name: .long, help: "Substring of AXDescription (case-insensitive).")
    var descriptionContains: String?

    @Option(name: .long, help: "Substring of AXValue (case-insensitive).")
    var valueContains: String?

    @Flag(name: .long, help: "Only enabled elements.")
    var enabledOnly: Bool = false

    @Flag(name: .long, help: "Only disabled elements.")
    var disabledOnly: Bool = false

    @Option(name: .long, help: "Maximum number of hits.")
    var limit: Int = 50

    @Option(name: .long, help: "Maximum tree depth to descend.")
    var maxDepth: Int = 64

    @Flag(name: .long, help: "Emit only axPath strings, one per line.")
    var pathsOnly: Bool = false

    func run() async throws {
        let criteria = FindCriteria(
            role: role, subrole: subrole, title: title,
            titleContains: titleContains, identifier: identifier,
            descriptionContains: descriptionContains, valueContains: valueContains,
            enabledOnly: enabledOnly, disabledOnly: disabledOnly)
        guard criteria.hasAnyFilter else {
            throw KageteError.failure(
                "No filters provided. Supply at least one of --role, --title, --title-contains, --id, etc.")
        }
        let resolved = try TargetResolver.resolve(target)
        let hits = try AXInspector.find(
            pid: resolved.pid, windowFilter: resolved.windowFilter,
            criteria: criteria, limit: limit, maxDepth: maxDepth)

        if pathsOnly {
            for h in hits { print(h.axPath) }
        } else {
            try JSON.print(hits)
        }
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a PNG screenshot of the target window with a coordinate grid overlay.")

    @OptionGroup var target: TargetOptions

    @Option(name: [.customShort("o"), .long], help: "Output PNG path.")
    var output: String

    @Flag(name: .long, help: "Skip the coordinate grid overlay.")
    var clean: Bool = false

    @Option(name: .long, help: "Grid spacing in screen points (default 200). Smaller = denser.")
    var gridPitch: Double = 200

    @Option(name: .long, help: "Output pixel scale relative to screen points (default 0.5 for agent consumption; 1 for native; 2 for retina).")
    var scale: Double = 0.5

    @Option(name: .long, help: "Crop to a window-relative region: \"x,y,w,h\" in screen points (e.g. \"400,200,800,600\"). Labels still show absolute screen coords.")
    var crop: String?

    func run() async throws {
        // Bootstrap AppKit's CGS session so Core Text / bitmap-context work
        // and the PNG writer both have what they need. Touching
        // NSApplication.shared on the main actor is the reliable init path
        // from an async CLI.
        await MainActor.run { _ = NSApplication.shared }
        let resolved = try TargetResolver.resolve(target)
        let url = URL(fileURLWithPath: output).absoluteURL

        var cropRect: CGRect? = nil
        if let c = crop {
            let parts = c.split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, parts[2] > 0, parts[3] > 0 else {
                throw KageteError.failure(
                    "--crop expects \"x,y,w,h\" with positive w and h (got \"\(c)\").")
            }
            cropRect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }

        try await Capture.screenshot(
            pid: resolved.pid, windowFilter: resolved.windowFilter,
            output: url,
            grid: !clean,
            gridPitch: CGFloat(gridPitch),
            captureScale: CGFloat(scale),
            crop: cropRect)
        print(url.path)
    }
}

struct Click: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click at a point or on an AX element.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "AX path of the element to click (preferred).")
    var axPath: String?

    @Option(name: .long, help: "Absolute x coordinate in screen points.")
    var x: Double?

    @Option(name: .long, help: "Absolute y coordinate in screen points.")
    var y: Double?

    @Option(name: .long, help: "Mouse button: left (default), right, middle.")
    var button: String = "left"

    @Option(name: .long, help: "Click count (1 single, 2 double, etc.).")
    var count: Int = 1

    @Flag(name: .long, inversion: .prefixedNo, help: "Activate the target app before clicking.")
    var activate: Bool = true

    @Flag(name: .long, help: "Skip the overlay pulse for this command.")
    var noOverlay: Bool = false

    @Flag(name: .long, help: "Force CGEvent click even when the element advertises AXPress.")
    var noAxPress: Bool = false

    @Flag(name: .long, help: "Print a small JSON report describing how the click was dispatched.")
    var json: Bool = false

    func run() async throws {
        guard let mb = MouseButton(rawValue: button.lowercased()) else {
            throw KageteError.failure("Unknown --button \(button). Use left/right/middle.")
        }

        let point: CGPoint
        var appLabel: String? = nil
        var element: AXUIElement? = nil
        var elementActions: [String] = []
        if let ax = axPath {
            let resolved = try TargetResolver.resolve(target)
            appLabel = resolved.app.localizedName
            if activate {
                try await Activator.activate(resolved)
            }
            let el = try AXInspector.locate(
                pid: resolved.pid, windowFilter: resolved.windowFilter, axPath: ax)
            element = el
            elementActions = AXInspector.actionNames(el)
            guard let center = AXInspector.screenCenter(of: el) else {
                throw KageteError.failure("Element at \(ax) has no resolvable frame.")
            }
            point = center
        } else if let cx = x, let cy = y {
            point = CGPoint(x: cx, y: cy)
        } else {
            throw KageteError.failure("Provide --ax-path (with --app/--bundle/--pid) or --x/--y.")
        }

        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: PointJSON(x: Double(point.x), y: Double(point.y)),
                label: count > 1 ? "click×\(count)" : "click",
                app: appLabel)))
        }

        // AXPress is a single-activation primitive — it doesn't express button
        // type or click count, so we only take the AX path for a plain left
        // single-click on a resolved element that advertises it.
        let canAxPress = !noAxPress && mb == .left && count == 1
            && element != nil && elementActions.contains(kAXPressAction)

        let method: String
        if canAxPress, let el = element {
            let status = AXUIElementPerformAction(el, kAXPressAction as CFString)
            if status == .success {
                method = "ax-press"
            } else {
                try Input.click(at: point, button: mb, count: count)
                method = "cg-event-fallback"
            }
        } else {
            try Input.click(at: point, button: mb, count: count)
            method = "cg-event"
        }

        if json {
            struct Report: Codable {
                let method: String
                let point: PointJSON
                let actions: [String]?
                let axPath: String?
            }
            try JSON.print(Report(
                method: method,
                point: PointJSON(x: Double(point.x), y: Double(point.y)),
                actions: elementActions.isEmpty ? nil : elementActions,
                axPath: axPath))
        }
    }
}

struct TypeText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type a string into the focused element.")

    @OptionGroup var target: TargetOptions

    @Argument(help: "Text to type.")
    var text: String

    @Flag(name: .long, inversion: .prefixedNo, help: "Activate the target app before typing (if one is specified).")
    var activate: Bool = true

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    func run() async throws {
        var appLabel: String? = nil
        if target.app != nil || target.bundle != nil || target.pid != nil {
            let resolved = try TargetResolver.resolve(target)
            appLabel = resolved.app.localizedName
            if activate {
                try await Activator.activate(resolved)
            }
        }
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(at: nil, label: "type", app: appLabel)))
        }
        try Input.type(text)
    }
}

struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Send a keyboard combo, e.g. cmd+s, shift+tab, f12.")

    @OptionGroup var target: TargetOptions

    @Argument(help: "Key combo, e.g. \"cmd+shift+4\".")
    var combo: String

    @Flag(name: .long, inversion: .prefixedNo, help: "Activate the target app before sending (if one is specified).")
    var activate: Bool = true

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    func run() async throws {
        var appLabel: String? = nil
        if target.app != nil || target.bundle != nil || target.pid != nil {
            let resolved = try TargetResolver.resolve(target)
            appLabel = resolved.app.localizedName
            if activate {
                try await Activator.activate(resolved)
            }
        }
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(at: nil, label: "key \(combo)", app: appLabel)))
        }
        let parsed = try KeyCodes.parse(combo)
        try Input.key(parsed)
    }
}

struct Scroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll the wheel at the current cursor position.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Horizontal scroll (positive = right).")
    var dx: Int32 = 0

    @Option(name: .long, help: "Vertical scroll (positive = up, negative = down).")
    var dy: Int32 = 0

    @Flag(name: .long, help: "Use pixel units instead of line units.")
    var pixels: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Activate the target app before scrolling (if one is specified).")
    var activate: Bool = true

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    func run() async throws {
        var appLabel: String? = nil
        if target.app != nil || target.bundle != nil || target.pid != nil {
            let resolved = try TargetResolver.resolve(target)
            appLabel = resolved.app.localizedName
            if activate {
                try await Activator.activate(resolved)
            }
        }
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(at: nil, label: "scroll", app: appLabel)))
        }
        try Input.scroll(dx: dx, dy: dy, lines: !pixels)
    }
}

struct Drag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drag",
        abstract: "Drag from one point (or AX element) to another.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Source AX path.")
    var fromAxPath: String?

    @Option(name: .long, help: "Target AX path.")
    var toAxPath: String?

    @Option(name: .long, help: "Source x (screen points).")
    var fromX: Double?

    @Option(name: .long, help: "Source y (screen points).")
    var fromY: Double?

    @Option(name: .long, help: "Target x (screen points).")
    var toX: Double?

    @Option(name: .long, help: "Target y (screen points).")
    var toY: Double?

    @Option(name: .long, help: "Number of interpolation steps.")
    var steps: Int = 20

    @Option(name: .long, help: "Press-and-hold duration before dragging (ms).")
    var holdMs: Int = 0

    @Option(name: .long, help: "Modifier flags, e.g. \"shift\" or \"cmd+alt\".")
    var mod: String = ""

    @Flag(name: .long, inversion: .prefixedNo, help: "Activate the target app first.")
    var activate: Bool = true

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    func run() async throws {
        let modifiers = try KeyCodes.parseModifiers(mod)
        let hasTargetFlags = target.app != nil || target.bundle != nil || target.pid != nil

        if fromAxPath != nil || toAxPath != nil {
            guard hasTargetFlags else {
                throw KageteError.failure("--from-ax-path / --to-ax-path require --app/--bundle/--pid.")
            }
        }

        var resolved: ResolvedTarget? = nil
        if hasTargetFlags {
            resolved = try TargetResolver.resolve(target)
            if activate, let r = resolved {
                try await Activator.activate(r)
            }
        }

        let start = try resolvePoint(
            axPath: fromAxPath, x: fromX, y: fromY, resolved: resolved, label: "source")
        let end = try resolvePoint(
            axPath: toAxPath, x: toX, y: toY, resolved: resolved, label: "target")

        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: PointJSON(x: Double(start.x), y: Double(start.y)),
                label: "drag",
                app: resolved?.app.localizedName)))
        }
        try Input.drag(
            from: start, to: end,
            steps: steps,
            holdMicros: UInt32(max(0, holdMs) * 1000),
            modifiers: modifiers)
    }

    private func resolvePoint(
        axPath: String?, x: Double?, y: Double?,
        resolved: ResolvedTarget?, label: String
    ) throws -> CGPoint {
        if let ax = axPath {
            guard let r = resolved else {
                throw KageteError.failure("--\(label)-ax-path requires --app/--bundle/--pid.")
            }
            let el = try AXInspector.locate(
                pid: r.pid, windowFilter: r.windowFilter, axPath: ax)
            guard let c = AXInspector.screenCenter(of: el) else {
                throw KageteError.failure("\(label) element has no resolvable frame.")
            }
            return c
        }
        if let cx = x, let cy = y {
            return CGPoint(x: cx, y: cy)
        }
        throw KageteError.failure("Provide --\(label)-ax-path or --\(label)-x/--\(label)-y.")
    }
}

struct Release: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Tell the awareness overlay the agent is done — shows ✓ and returns control.")

    @Argument(help: "Optional label to show instead of \"control returned\".")
    var label: String = "control returned"

    func run() async throws {
        OverlayClient.notify(.release(label: label))
    }
}

struct Raise: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "raise",
        abstract: "Raise a target window via the AX API (bypasses the activation broker).")

    @OptionGroup var target: TargetOptions

    @Flag(name: .long, help: "Emit JSON with a post-raise report.")
    var json: Bool = false

    func run() async throws {
        let resolved = try TargetResolver.resolve(target)
        let report = try AXRaise.raise(pid: resolved.pid, windowFilter: resolved.windowFilter)
        if json {
            struct Out: Codable {
                let app: String?
                let setFrontmost: Bool
                let raisedWindow: Bool
                let setMain: Bool
                let frontmostAfter: String?
            }
            try JSON.print(Out(
                app: resolved.app.localizedName,
                setFrontmost: report.setFrontmost,
                raisedWindow: report.raisedWindow,
                setMain: report.setMain,
                frontmostAfter: report.frontmostAfter))
        } else {
            print("raise \(resolved.app.localizedName ?? "?") pid=\(resolved.pid)")
            print("  AXFrontmost      : \(report.setFrontmost ? "set" : "FAILED")")
            print("  AXRaise(window)  : \(report.raisedWindow ? "ok" : "FAILED")")
            print("  AXMain(window)   : \(report.setMain ? "set" : "FAILED")")
            print("  frontmost after  : \(report.frontmostAfter ?? "?")")
        }
    }
}

struct Overlay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overlay",
        abstract: "Control the awareness overlay daemon.",
        subcommands: [OverlayStatus.self, OverlayStop.self])
}

struct OverlayStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Query the overlay daemon status.")

    func run() async throws {
        guard OverlayClient.isEnabled else {
            print("overlay disabled (KAGETE_OVERLAY=0)")
            return
        }
        if let reply = OverlayClient.query(.status) {
            print(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            print("overlay: not running")
        }
    }
}

struct OverlayStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Force-stop the overlay daemon.")

    func run() async throws {
        OverlayClient.notify(.stop)
        print("overlay: stop sent")
    }
}

struct OverlayDaemonEntry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_overlay-daemon",
        abstract: "Internal — the overlay helper process (not for direct use).",
        shouldDisplay: false)

    func run() async throws {
        await MainActor.run {
            OverlayDaemon.run()
        }
    }
}
