import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

@main
struct Kagete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kagete",
        abstract: "Agent computer-use CLI for macOS: inspect windows, screenshot, click, type.",
        version: kageteVersion,
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

    @Flag(name: .long, help: "Print a human-readable report instead of the JSON envelope.")
    var text: Bool = false

    struct DoctorResult: Codable {
        let accessibility: Bool
        let screenRecording: Bool
        let allGranted: Bool
    }

    func run() async throws {
        if prompt {
            if !Permissions.accessibility { Permissions.promptAccessibility() }
            if !Permissions.screenRecording { Permissions.promptScreenRecording() }
        }

        let ax = Permissions.accessibility
        let sr = Permissions.screenRecording
        let result = DoctorResult(accessibility: ax, screenRecording: sr, allGranted: ax && sr)

        if text {
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
            return
        }

        let missing = [(!ax ? "Accessibility" : nil), (!sr ? "Screen Recording" : nil)].compactMap { $0 }
        let hint: String? = missing.isEmpty
            ? nil
            : "Missing: \(missing.joined(separator: ", ")). Rerun with --prompt to trigger system dialogs."
        try CLIOut.ok(command: "doctor", result: result, hint: hint)
        if !result.allGranted { throw ExitCode(1) }
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

    struct WindowsResult: Codable {
        let count: Int
        let windows: [WindowRecord]
    }

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
        let hint: String? = records.isEmpty && (app != nil || bundle != nil || pid != nil)
            ? "No windows match the filter. The app may be hidden, minimized, or have no windowLayer=0 windows."
            : nil
        try CLIOut.ok(
            command: "windows",
            result: WindowsResult(count: records.count, windows: records),
            hint: hint)
    }
}

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Summarize the AX tree of a target window (use --tree for the full dump).")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Maximum tree depth to descend.")
    var maxDepth: Int = 12

    @Flag(name: .long, help: "Emit the full AX node tree instead of a summary. Combine with --with-actions to include per-node AX actions.")
    var tree: Bool = false

    @Flag(name: .long, help: "With --tree: emit the full raw tree without pruning unlabeled AXUnknown nodes.")
    var full: Bool = false

    @Flag(name: .long, help: "With --tree: include AX action names per node (extra IPC per element — slow on large trees).")
    var withActions: Bool = false

    func run() async throws {
        do {
            try runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                InspectSummary.self, command: "inspect",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() throws {
        let resolved = try TargetResolver.resolve(target)
        if tree {
            let node = try AXInspector.inspect(
                pid: resolved.pid, windowFilter: resolved.windowFilter,
                maxDepth: maxDepth, compact: !full, withActions: withActions)
            try CLIOut.ok(
                command: "inspect",
                target: TargetJSON(resolved: resolved),
                result: node)
            return
        }
        let summary = try AXInspector.summarize(
            pid: resolved.pid, windowFilter: resolved.windowFilter,
            maxDepth: maxDepth)
        let hint: String?
        if summary.actionableCount == 0 {
            hint = "No AXPress/Increment/Decrement elements found — the window may use custom-drawn UI; consider Visual path (screenshot + coord click)."
        } else if summary.totalNodes > 200 {
            hint = "Large tree (\(summary.totalNodes) nodes). Use `kagete find` with --role/--title to drill in, or `inspect --tree` for the full dump."
        } else {
            hint = "Use `kagete find` to target specific elements, or `inspect --tree` for the full node tree."
        }
        try CLIOut.ok(
            command: "inspect",
            target: TargetJSON(resolved: resolved),
            result: summary, hint: hint)
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

    @Flag(name: .long, help: "Emit only axPath strings, one per line (plain text, not an envelope).")
    var pathsOnly: Bool = false

    struct FindResult: Codable {
        let count: Int
        let truncated: Bool
        let limit: Int
        let disabledCount: Int
        let hits: [AXHit]
    }

    func run() async throws {
        do {
            try runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                FindResult.self, command: "find",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() throws {
        let criteria = FindCriteria(
            role: role, subrole: subrole, title: title,
            titleContains: titleContains, identifier: identifier,
            descriptionContains: descriptionContains, valueContains: valueContains,
            enabledOnly: enabledOnly, disabledOnly: disabledOnly)
        guard criteria.hasAnyFilter else {
            throw KageteError.invalidArgument(
                "No filters provided. Supply at least one of --role, --title, --title-contains, --id, etc.")
        }
        let resolved = try TargetResolver.resolve(target)
        let hits = try AXInspector.find(
            pid: resolved.pid, windowFilter: resolved.windowFilter,
            criteria: criteria, limit: limit, maxDepth: maxDepth)

        if pathsOnly {
            for h in hits { print(h.axPath) }
            return
        }

        let disabled = hits.filter { $0.enabled == false }.count
        let truncated = hits.count >= limit
        let result = FindResult(
            count: hits.count,
            truncated: truncated,
            limit: limit,
            disabledCount: disabled,
            hits: hits)

        let hint: String?
        if hits.isEmpty {
            hint = "No matches. Try broader filters (--title-contains, --role) or `inspect` the window to survey what's there."
        } else if truncated {
            hint = "Hit --limit (\(limit)). Narrow with --enabled-only / --title-contains to see the rest."
        } else if hits.count == 1, hits[0].actions?.contains(kAXPressAction) == true {
            hint = "One AXPress hit — pass its axPath to `kagete click --ax-path`."
        } else if disabled > 0, !enabledOnly {
            hint = "\(disabled) of \(hits.count) hits are AXDisabled — add --enabled-only to filter them out."
        } else {
            hint = nil
        }

        try CLIOut.ok(
            command: "find",
            target: TargetJSON(resolved: resolved),
            result: result, hint: hint)
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

    @Option(name: .long, help: ArgumentHelp(
        "Output pixel scale relative to screen points (default 0.5 for agent consumption; 1 for native; 2 for retina).",
        visibility: .hidden))
    var scale: Double = 0.5

    @Option(name: .long, help: "Crop to a window-relative region: \"x,y,w,h\" in screen points (e.g. \"400,200,800,600\"). Labels still show absolute screen coords.")
    var crop: String?

    @Flag(name: .long, help: "Print only the output path (shell-friendly) instead of the JSON envelope.")
    var text: Bool = false

    struct ScreenshotResult: Codable {
        let path: String
        let grid: Bool
        let cropped: Bool
    }

    func run() async throws {
        do {
            try await runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                ScreenshotResult.self, command: "screenshot",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
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
                throw KageteError.invalidArgument(
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

        if text {
            print(url.path)
            return
        }
        try CLIOut.ok(
            command: "screenshot",
            target: TargetJSON(resolved: resolved),
            result: ScreenshotResult(
                path: url.path, grid: !clean, cropped: cropRect != nil))
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

    @Flag(name: .long, help: "Print only a terse one-line summary on success instead of the JSON envelope.")
    var text: Bool = false

    struct ClickResult: Codable {
        let method: String
        let button: String
        let count: Int
        let point: PointJSON
        let element: ElementSummary?

        struct ElementSummary: Codable {
            let axPath: String
            let role: String?
            let title: String?
            let actions: [String]
        }
    }

    static func shouldResolveTarget(axPath: String?, target: TargetOptions, activate: Bool) -> Bool {
        axPath != nil || (activate && target.hasAppSelector)
    }

    func run() async throws {
        do {
            try await runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                ClickResult.self, command: "click",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        guard let mb = MouseButton(rawValue: button.lowercased()) else {
            throw KageteError.invalidArgument("Unknown --button \(button). Use left/right/middle.")
        }

        let point: CGPoint
        let resolvedTarget = Self.shouldResolveTarget(
            axPath: axPath,
            target: target,
            activate: activate) ? try TargetResolver.resolve(target) : nil
        let appLabel = resolvedTarget?.app.localizedName
        var element: AXUIElement? = nil
        var elementBundle: AXBundle? = nil
        var elementActions: [String] = []
        if let ax = axPath {
            guard let resolvedTarget else {
                throw KageteError.failure("Internal error: missing resolved target for AX click.")
            }
            try await Activator.activate(resolvedTarget)
            let el = try AXInspector.locate(
                pid: resolvedTarget.pid, windowFilter: resolvedTarget.windowFilter, axPath: ax)
            element = el
            elementBundle = AXInspector.bundle(for: el)
            elementActions = AXInspector.actionNames(el)
            guard let center = AXInspector.screenCenter(of: el) else {
                throw KageteError.failure("Element at \(ax) has no resolvable frame.")
            }
            point = center
        } else if let cx = x, let cy = y {
            if activate, let resolvedTarget {
                try await Activator.activate(resolvedTarget)
            }
            point = CGPoint(x: cx, y: cy)
        } else {
            throw KageteError.invalidArgument("Provide --ax-path (with --app/--bundle/--pid) or --x/--y.")
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

        let result = ClickResult(
            method: method,
            button: mb.rawValue,
            count: count,
            point: PointJSON(x: Double(point.x), y: Double(point.y)),
            element: axPath.map { path in
                ClickResult.ElementSummary(
                    axPath: path,
                    role: elementBundle?.role,
                    title: elementBundle?.title,
                    actions: elementActions)
            })

        let verify = buildVerify()
        let hint = buildHint(method: method)

        if text {
            print("click: \(method) @ (\(Int(point.x)),\(Int(point.y)))")
            return
        }

        try CLIOut.ok(
            command: "click",
            target: resolvedTarget.map { TargetJSON(resolved: $0) },
            result: result, verify: verify, hint: hint)
    }

    // Click verify intentionally reports cursor only. App-level keyboard
    // focus (AXFocusedUIElement) is unrelated to "what was clicked":
    // buttons usually don't take focus, so the field surfaces whatever
    // sidebar/list happened to hold focus before the click and misleads
    // the agent into reasoning about an unrelated element. Use `find` /
    // `inspect` / `screenshot` if you need to verify the click target
    // itself.
    private func buildVerify() -> VerifyJSON? {
        let cursor = CGEvent(source: nil).map {
            PointJSON(x: Double($0.location.x), y: Double($0.location.y))
        }
        return VerifyJSON(focusedAxPath: nil, focusedRole: nil,
                          focusedTitle: nil, cursor: cursor)
    }

    private func buildHint(method: String) -> String? {
        if method == "cg-event-fallback" {
            return "Element advertised AXPress but it failed — UI may have intercepted the event."
        }
        return nil
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

    struct TypeResult: Codable {
        let length: Int
    }

    func run() async throws {
        do {
            try await runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                TypeResult.self, command: "type",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        var resolved: ResolvedTarget? = nil
        if target.hasAppSelector {
            resolved = try TargetResolver.resolve(target)
            if activate, let r = resolved {
                try await Activator.activate(r)
            }
        }
        // Auto-focus pass: a synthesized click moves the cursor visually
        // but doesn't always install first responder — common on
        // Electron, custom NSViews, and any UI whose mouseDown handler
        // doesn't call makeFirstResponder. If the app's currently
        // focused element isn't a known text input, ask AX for the
        // element under the cursor and try to focus it. Best-effort:
        // a no-op when AX can't help (web inputs, locked-down apps).
        if let r = resolved {
            if AXInspector.ensureTextFocus(pid: r.pid) {
                // Let the app's focus-changed handler run. Chromium /
                // Electron route focus through the DOM event loop and
                // need a few turns before keystrokes land in the new
                // input. Without this, the first chars often go to
                // /dev/null.
                usleep(120_000)
            }
        }
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(at: nil, label: "type", app: resolved?.app.localizedName)))
        }
        try Input.type(text)

        let verify = resolved.map { r -> VerifyJSON in
            let f = AXInspector.focusedSummary(pid: r.pid)
            return VerifyJSON(focusedAxPath: nil, focusedRole: f?.role,
                              focusedTitle: f?.title, cursor: nil)
        }
        let hint: String? = (verify != nil && verify?.focusedRole == nil)
            ? "No focused element observed — text may have gone to a background app. Click into a field first."
            : nil
        try CLIOut.ok(
            command: "type",
            target: resolved.map { TargetJSON(resolved: $0) },
            result: TypeResult(length: text.count),
            verify: verify, hint: hint)
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

    struct KeyResult: Codable {
        let combo: String
        let keyCode: Int
    }

    func run() async throws {
        do {
            try await runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                KeyResult.self, command: "key",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        var resolved: ResolvedTarget? = nil
        if target.hasAppSelector {
            resolved = try TargetResolver.resolve(target)
            if activate, let r = resolved {
                try await Activator.activate(r)
            }
        }
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(at: nil, label: "key \(combo)", app: resolved?.app.localizedName)))
        }
        let parsed = try KeyCodes.parse(combo)
        try Input.key(parsed)

        let verify = resolved.map { r -> VerifyJSON in
            let f = AXInspector.focusedSummary(pid: r.pid)
            return VerifyJSON(focusedAxPath: nil, focusedRole: f?.role,
                              focusedTitle: f?.title, cursor: nil)
        }
        try CLIOut.ok(
            command: "key",
            target: resolved.map { TargetJSON(resolved: $0) },
            result: KeyResult(combo: combo, keyCode: Int(parsed.keyCode)),
            verify: verify)
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

    struct ScrollResult: Codable {
        let dx: Int32
        let dy: Int32
        let units: String
    }

    func run() async throws {
        do {
            try await runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                ScrollResult.self, command: "scroll",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        var resolved: ResolvedTarget? = nil
        if target.hasAppSelector {
            resolved = try TargetResolver.resolve(target)
            if activate, let r = resolved {
                try await Activator.activate(r)
            }
        }
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(at: nil, label: "scroll", app: resolved?.app.localizedName)))
        }
        try Input.scroll(dx: dx, dy: dy, lines: !pixels)

        try CLIOut.ok(
            command: "scroll",
            target: resolved.map { TargetJSON(resolved: $0) },
            result: ScrollResult(dx: dx, dy: dy, units: pixels ? "pixels" : "lines"))
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

    struct DragResult: Codable {
        let from: PointJSON
        let to: PointJSON
        let steps: Int
        let holdMs: Int
        let modifiers: String
    }

    func run() async throws {
        do {
            try await runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                DragResult.self, command: "drag",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        let modifiers = try KeyCodes.parseModifiers(mod)
        let hasTargetFlags = target.app != nil || target.bundle != nil || target.pid != nil

        if fromAxPath != nil || toAxPath != nil {
            guard hasTargetFlags else {
                throw KageteError.invalidArgument("--from-ax-path / --to-ax-path require --app/--bundle/--pid.")
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

        let cursor = CGEvent(source: nil).map {
            PointJSON(x: Double($0.location.x), y: Double($0.location.y))
        }
        try CLIOut.ok(
            command: "drag",
            target: resolved.map { TargetJSON(resolved: $0) },
            result: DragResult(
                from: PointJSON(x: Double(start.x), y: Double(start.y)),
                to: PointJSON(x: Double(end.x), y: Double(end.y)),
                steps: steps, holdMs: holdMs, modifiers: mod),
            verify: VerifyJSON(focusedAxPath: nil, focusedRole: nil,
                               focusedTitle: nil, cursor: cursor))
    }

    private func resolvePoint(
        axPath: String?, x: Double?, y: Double?,
        resolved: ResolvedTarget?, label: String
    ) throws -> CGPoint {
        if let ax = axPath {
            guard let r = resolved else {
                throw KageteError.invalidArgument("--\(label)-ax-path requires --app/--bundle/--pid.")
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
        throw KageteError.invalidArgument("Provide --\(label)-ax-path or --\(label)-x/--\(label)-y.")
    }
}

struct Release: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Tell the awareness overlay the agent is done — shows ✓ and returns control.")

    @Argument(help: "Optional label to show instead of \"control returned\".")
    var label: String = "control returned"

    struct ReleaseResult: Codable {
        let label: String
    }

    func run() async throws {
        OverlayClient.notify(.release(label: label))
        try CLIOut.ok(command: "release", result: ReleaseResult(label: label))
    }
}

struct Raise: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "raise",
        abstract: "Raise a target window via the AX API (bypasses the activation broker).")

    @OptionGroup var target: TargetOptions

    @Flag(name: .long, help: "Print a human-readable report instead of the JSON envelope.")
    var text: Bool = false

    struct RaiseResult: Codable {
        let setFrontmost: Bool
        let raisedWindow: Bool
        let setMain: Bool
        let frontmostAfter: String?
        let changedFocus: Bool
    }

    func run() async throws {
        do {
            try runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                RaiseResult.self, command: "raise",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() throws {
        let resolved = try TargetResolver.resolve(target)
        let report = try AXRaise.raise(pid: resolved.pid, windowFilter: resolved.windowFilter)
        let result = RaiseResult(
            setFrontmost: report.setFrontmost,
            raisedWindow: report.raisedWindow,
            setMain: report.setMain,
            frontmostAfter: report.frontmostAfter,
            changedFocus: report.changedFocus)

        if text {
            print("raise \(resolved.app.localizedName ?? "?") pid=\(resolved.pid)")
            print("  AXFrontmost      : \(report.setFrontmost ? "set" : "FAILED")")
            print("  AXRaise(window)  : \(report.raisedWindow ? "ok" : "FAILED")")
            print("  AXMain(window)   : \(report.setMain ? "set" : "FAILED")")
            print("  frontmost after  : \(report.frontmostAfter ?? "?")")
            return
        }

        let hint: String? = report.changedFocus
            ? nil
            : "AX raise did not change focus — another app may be holding it (e.g. CleanShot X recorder). Try --no-activate=false on the next action."
        try CLIOut.ok(
            command: "raise",
            target: TargetJSON(resolved: resolved),
            result: result, hint: hint)
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
