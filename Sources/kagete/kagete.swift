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
            Press.self,
            Action.self,
            Focus.self,
            ScrollTo.self,
            Activate.self,
            ClickAt.self,
            Move.self,
            TypeText.self,
            SetValue.self,
            Key.self,
            Scroll.self,
            Drag.self,
            Wait.self,
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

        let host = Permissions.hostLabel
        if text {
            print("kagete doctor")
            print("  Accessibility     : \(ax ? "granted" : "MISSING")")
            print("  Screen Recording  : \(sr ? "granted" : "MISSING")")
            if !ax || !sr {
                print("")
                print("macOS grants these permissions *per-process* to whichever")
                print("binary owns the process tree, not kagete itself. Grant")
                print("them to \(host) (the process that launched kagete):")
            }
            if !ax {
                print("    → System Settings → Privacy & Security → Accessibility → add \(host).")
            }
            if !sr {
                print("    → System Settings → Privacy & Security → Screen Recording → add \(host).")
            }
            if ax && sr {
                print("\nAll good, leader. ✓")
            } else {
                print("")
                print("Or rerun with --prompt to trigger the system dialogs.")
                throw ExitCode(1)
            }
            return
        }

        let missing = [(!ax ? "Accessibility" : nil), (!sr ? "Screen Recording" : nil)].compactMap { $0 }
        let hint: String? = missing.isEmpty
            ? nil
            : "Missing: \(missing.joined(separator: ", ")). macOS grants these per-process to the parent. Grant to \"\(host)\" (not kagete) in System Settings → Privacy & Security. Or rerun with --prompt."
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

    @Flag(name: .long, help: "With --tree: include AX action names per node. Adds one IPC per element and is slow on large trees.")
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
            hint = "No AXPress/Increment/Decrement elements found. The window may use custom-drawn UI; consider the Visual path (screenshot + coord click)."
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

    @Option(name: .long, help: "Case-insensitive substring matched across every label the element exposes (title, value, description, help, identifier). Use whichever phrase you'd read off the screen. kagete does not ask you to guess which field carries it.")
    var textContains: String?

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
            role: role, subrole: subrole,
            textContains: textContains,
            enabledOnly: enabledOnly, disabledOnly: disabledOnly)
        guard criteria.hasAnyFilter else {
            throw KageteError.invalidArgument(
                "No filters provided. Supply at least one of --role, --subrole, --text-contains, --enabled-only, --disabled-only.")
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
            hint = "No matches. Broaden the query (drop --role, shorten --text-contains) or run `kagete inspect --tree` to survey what's there."
        } else if truncated {
            hint = "Hit --limit (\(limit)). Narrow with --enabled-only / --title-contains to see the rest."
        } else if hits.count == 1, hits[0].actions?.contains(kAXPressAction) == true {
            hint = "One AXPress hit. Pass its axPath to `kagete press --ax-path`."
        } else if disabled > 0, !enabledOnly {
            hint = "\(disabled) of \(hits.count) hits are AXDisabled. Add --enabled-only to filter them out."
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

    @Option(name: .long, help: "Grid spacing in screen points (default 100). Smaller = denser.")
    var gridPitch: Double = 100

    @Option(name: .long, help: ArgumentHelp(
        "Output pixel scale relative to screen points (default 0.8 for agent consumption; 1 for native; 2 for retina).",
        visibility: .hidden))
    var scale: Double = 0.8

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

        // Refresh-only: extend the idle timer and update the pill *if* an
        // overlay is already running, but never spawn one just for a capture.
        OverlayClient.notifyIfRunning(.pulse(.init(
            at: nil, label: "screenshot", app: resolved.app.localizedName)))

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

// MARK: - AX semantic action primitives
//
// The following commands do exactly one thing at the AX layer each — no
// activation, no cursor motion, no HID traffic, no fallback. They depend
// only on the AX API being willing to dispatch the requested action or
// write the requested attribute. Agents compose these with HID primitives
// and `activate` as needed; the binary does not guess.

/// `kagete press` — fire `kAXPressAction` on an element. No fallback to
/// CGEvent; no auto-activate. If the element doesn't advertise AXPress,
/// returns `AX_ACTION_UNSUPPORTED` with the list of actions the element
/// *does* advertise, so the agent can pick the next primitive.
struct Press: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Perform kAXPressAction on an element. No fallback, no activate.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "AX path of the element to press.")
    var axPath: String

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    struct PressResult: Codable {
        let axPath: String
        let role: String?
        let title: String?
        let actions: [String]
    }

    func run() async throws {
        do { try await runInner() }
        catch let err as KageteError {
            try CLIOut.fail(
                PressResult.self, command: "press",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        let resolved = try TargetResolver.resolve(target)
        let el = try AXInspector.locate(
            pid: resolved.pid, windowFilter: resolved.windowFilter, axPath: axPath)
        let b = AXInspector.bundle(for: el)
        let actions = AXInspector.actionNames(el)

        guard actions.contains(kAXPressAction) else {
            throw KageteError.failure(
                "AX action unsupported: element at \(axPath) (role=\(b.role ?? "?")) does not advertise AXPress. Advertised actions: \(actions.joined(separator: ", "))")
        }

        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: nil, label: "press", app: resolved.app.localizedName)))
        }

        let status = AXInspector.performActionRaw(el, action: kAXPressAction)
        guard status == .success else {
            throw KageteError.failure(
                "AX action failed on \(axPath) (AXError \(status.rawValue)). The element advertised AXPress but the app rejected the call.")
        }

        let result = PressResult(
            axPath: axPath, role: b.role, title: b.title, actions: actions)
        try CLIOut.ok(
            command: "press",
            target: TargetJSON(resolved: resolved),
            result: result)
    }
}

/// `kagete action` — generic AX action dispatcher. Allowlist of well-known
/// names; anything else is `INVALID_ARGUMENT`. Same contract as `press`:
/// probe first via `actionNames`, then fire. No fallback.
struct Action: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "action",
        abstract: "Perform a named AX action (AXShowMenu, AXIncrement, AXDecrement, AXPick, AXConfirm, AXCancel).")

    /// Whitelist keeps the surface well-defined. `press` and `scroll-to`
    /// are their own verbs so they don't need to appear here.
    static let allowed: Set<String> = [
        "AXShowMenu", "AXIncrement", "AXDecrement",
        "AXPick", "AXConfirm", "AXCancel",
    ]

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "AX path of the element to act on.")
    var axPath: String

    @Option(name: .long, help: "Action name (e.g. AXShowMenu).")
    var name: String

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    struct ActionResult: Codable {
        let axPath: String
        let role: String?
        let title: String?
        let action: String
        let actions: [String]
    }

    func run() async throws {
        do { try await runInner() }
        catch let err as KageteError {
            try CLIOut.fail(
                ActionResult.self, command: "action",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        guard Self.allowed.contains(name) else {
            throw KageteError.invalidArgument(
                "Unknown action \"\(name)\". Allowed: \(Self.allowed.sorted().joined(separator: ", ")). Use `kagete press` for AXPress and `kagete scroll-to` for AXScrollToVisible.")
        }

        let resolved = try TargetResolver.resolve(target)
        let el = try AXInspector.locate(
            pid: resolved.pid, windowFilter: resolved.windowFilter, axPath: axPath)
        let b = AXInspector.bundle(for: el)
        let actions = AXInspector.actionNames(el)

        guard actions.contains(name) else {
            throw KageteError.failure(
                "AX action unsupported: element at \(axPath) (role=\(b.role ?? "?")) does not advertise \(name). Advertised actions: \(actions.joined(separator: ", "))")
        }

        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: nil, label: name, app: resolved.app.localizedName)))
        }

        let status = AXInspector.performActionRaw(el, action: name)
        guard status == .success else {
            throw KageteError.failure(
                "AX action failed on \(axPath) for \(name) (AXError \(status.rawValue)).")
        }

        let result = ActionResult(
            axPath: axPath, role: b.role, title: b.title,
            action: name, actions: actions)
        try CLIOut.ok(
            command: "action",
            target: TargetJSON(resolved: resolved),
            result: result)
    }
}

/// `kagete focus` — set `kAXFocusedAttribute = true`. Replaces the hidden
/// `ensureTextFocus` call that `type` used to do. Agent calls this
/// explicitly before PID-targeted typing when needed.
struct Focus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Set kAXFocusedAttribute = true on an element.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "AX path of the element to focus.")
    var axPath: String

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    struct FocusResult: Codable {
        let axPath: String
        let role: String?
        let title: String?
    }

    func run() async throws {
        do { try await runInner() }
        catch let err as KageteError {
            try CLIOut.fail(
                FocusResult.self, command: "focus",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        let resolved = try TargetResolver.resolve(target)
        let el = try AXInspector.locate(
            pid: resolved.pid, windowFilter: resolved.windowFilter, axPath: axPath)
        let b = AXInspector.bundle(for: el)

        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: nil, label: "focus", app: resolved.app.localizedName)))
        }

        let status = AXInspector.setFocused(el)
        guard status == .success else {
            throw KageteError.failure(
                "AX focus failed on \(axPath) (AXError \(status.rawValue)). The element rejected kAXFocusedAttribute. Common on read-only labels, custom NSViews, or web content routed through the DOM.")
        }

        // Settle window. `AXUIElementSetAttributeValue(kAXFocusedAttribute)`
        // is acknowledged synchronously but the app's responder-chain
        // install is async — Chromium / Electron / DOM-backed fields all
        // route focus through their own event loop and need several
        // turns before keystrokes route to the new first responder. If
        // we return before that lands, a following `kagete type --app …`
        // drops the first characters (or the whole payload).
        //
        // This keeps `focus` a single-step primitive from the agent's
        // POV — "when this returns, focus is installed" — without
        // embedding a fallback or conditional branch.
        usleep(120_000)

        try CLIOut.ok(
            command: "focus",
            target: TargetJSON(resolved: resolved),
            result: FocusResult(axPath: axPath, role: b.role, title: b.title))
    }
}

/// `kagete scroll-to` — perform `AXScrollToVisible`. Semantic scroll,
/// no wheel events, no cursor motion. Only works on elements whose parent
/// scroll area advertises the action.
struct ScrollTo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll-to",
        abstract: "Perform AXScrollToVisible on an element.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "AX path of the element to scroll into view.")
    var axPath: String

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    struct ScrollToResult: Codable {
        let axPath: String
        let role: String?
        let title: String?
    }

    func run() async throws {
        do { try await runInner() }
        catch let err as KageteError {
            try CLIOut.fail(
                ScrollToResult.self, command: "scroll-to",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        let resolved = try TargetResolver.resolve(target)
        let el = try AXInspector.locate(
            pid: resolved.pid, windowFilter: resolved.windowFilter, axPath: axPath)
        let b = AXInspector.bundle(for: el)
        let actions = AXInspector.actionNames(el)

        guard actions.contains("AXScrollToVisible") else {
            throw KageteError.failure(
                "AX action unsupported: element at \(axPath) (role=\(b.role ?? "?")) does not advertise AXScrollToVisible. Advertised actions: \(actions.joined(separator: ", "))")
        }

        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: nil, label: "scroll-to", app: resolved.app.localizedName)))
        }

        let status = AXInspector.performActionRaw(el, action: "AXScrollToVisible")
        guard status == .success else {
            throw KageteError.failure(
                "AX action failed on \(axPath) for AXScrollToVisible (AXError \(status.rawValue)).")
        }

        try CLIOut.ok(
            command: "scroll-to",
            target: TargetJSON(resolved: resolved),
            result: ScrollToResult(axPath: axPath, role: b.role, title: b.title))
    }
}

// MARK: - App control

/// `kagete activate` — standalone activation primitive. No `.auto` fallback:
/// the agent picks `--method app` (NSRunningApplication.activate),
/// `--method ax` (AX frontmost + raise), or `--method both`. Default is
/// `app` — the classic path that most agents expect.
struct Activate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activate",
        abstract: "Bring the target app to the foreground.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Activation method: app | ax | both.")
    var method: String = "app"

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    struct ActivateResult: Codable {
        let method: String
        let frontmostAfterPid: Int32?
        let frontmostAfterName: String?
        let changed: Bool
    }

    func run() async throws {
        do { try await runInner() }
        catch let err as KageteError {
            try CLIOut.fail(
                ActivateResult.self, command: "activate",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        guard let m = Activator.Method(rawValue: method.lowercased()) else {
            throw KageteError.invalidArgument("Unknown --method \(method). Use app, ax, or both.")
        }
        // `--method app` is window-unaware: `NSRunningApplication.activate()`
        // brings the whole app forward and whichever window was most
        // recently active takes focus. Agents that supplied `--window` in
        // good faith would silently get the wrong one. Only `ax` / `both`
        // route `windowFilter` through `AXRaise.raise(pid:windowFilter:)`,
        // so reject the mismatch rather than pretend we honored the flag.
        if m == .app, target.window != nil {
            throw KageteError.invalidArgument(
                "--window is ignored by --method app (NSRunningApplication.activate() is window-unaware). Use --method ax or --method both to raise a specific window.")
        }
        let resolved = try TargetResolver.resolve(target)
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: nil, label: "activate", app: resolved.app.localizedName)))
        }
        // Compare by PID, not by `localizedName`. With a second instance
        // of the same app already frontmost (classic `open -n` scenario),
        // the name matches the target even though the requested process
        // never came forward. PID is the authoritative identity.
        let beforePid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try await Activator.activateExplicit(resolved, method: m)
        let afterApp = NSWorkspace.shared.frontmostApplication
        let afterPid = afterApp?.processIdentifier
        let afterName = afterApp?.localizedName
        let changed = afterPid != beforePid

        if afterPid != resolved.pid {
            throw KageteError.failure(
                "Activate failed: target pid \(resolved.pid) (\(resolved.app.localizedName ?? "?")) is not frontmost after activation (frontmost pid=\(afterPid.map { String($0) } ?? "?"), name=\(afterName ?? "?")).")
        }

        try CLIOut.ok(
            command: "activate",
            target: TargetJSON(resolved: resolved),
            result: ActivateResult(
                method: m.rawValue,
                frontmostAfterPid: afterPid,
                frontmostAfterName: afterName,
                changed: changed))
    }
}

// MARK: - HID primitives (cursor/keyboard synthesis)

/// `kagete click-at` — synthesize a click at exact screen coords. Nothing
/// else happens: no cursor warp, no activate, no AX lookup. Use `move`
/// first if the target depends on prior pointer motion. Use `activate`
/// first if the target refuses to accept clicks while backgrounded.
struct ClickAt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click-at",
        abstract: "Synthesize a CGEvent click at (x, y). No warp, no activate.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Absolute x coordinate in screen points.")
    var x: Double

    @Option(name: .long, help: "Absolute y coordinate in screen points.")
    var y: Double

    @Option(name: .long, help: "Mouse button: left (default), right, middle.")
    var button: String = "left"

    @Option(name: .long, help: "Click count (1 single, 2 double, etc.).")
    var count: Int = 1

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    struct ClickAtResult: Codable {
        let button: String
        let count: Int
        let point: PointJSON
    }

    func run() async throws {
        do { try await runInner() }
        catch let err as KageteError {
            try CLIOut.fail(
                ClickAtResult.self, command: "click-at",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        guard let mb = MouseButton(rawValue: button.lowercased()) else {
            throw KageteError.invalidArgument("Unknown --button \(button). Use left/right/middle.")
        }
        try target.assertNoWindowFilter(command: "click-at")
        let resolved: ResolvedTarget? = target.hasAppSelector
            ? try TargetResolver.resolve(target) : nil
        let point = CGPoint(x: x, y: y)
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: PointJSON(x: x, y: y),
                label: count > 1 ? "click×\(count)" : "click",
                app: resolved?.app.localizedName)))
        }
        try Input.click(at: point, button: mb, count: count, toPid: resolved?.pid)
        try CLIOut.ok(
            command: "click-at",
            target: resolved.map { TargetJSON(resolved: $0) },
            result: ClickAtResult(
                button: mb.rawValue, count: count,
                point: PointJSON(x: x, y: y)))
    }
}

/// `kagete move` — cursor warp to (x, y). No click, no drag. Pure primitive.
struct Move: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Warp the cursor to (x, y).")

    @Option(name: .long, help: "Absolute x coordinate in screen points.")
    var x: Double

    @Option(name: .long, help: "Absolute y coordinate in screen points.")
    var y: Double

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    struct MoveResult: Codable {
        let point: PointJSON
    }

    func run() async throws {
        do {
            if !noOverlay {
                OverlayClient.notify(.pulse(.init(
                    at: PointJSON(x: x, y: y), label: "move", app: nil)))
            }
            try Input.move(to: CGPoint(x: x, y: y))
            try CLIOut.ok(
                command: "move",
                result: MoveResult(point: PointJSON(x: x, y: y)))
        } catch let err as KageteError {
            try CLIOut.fail(
                MoveResult.self, command: "move", error: err)
        }
    }
}

/// `kagete type` — synthesize Unicode text. No auto-activate, no auto-focus.
/// The agent calls `activate` / `focus` explicitly beforehand when needed.
/// When a target is resolved (`--app` / `--bundle` / `--pid`), events route
/// through `CGEvent.postToPid` so they reach only that process; otherwise
/// they go through the global HID tap ("type into whoever has focus").
struct TypeText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Synthesize Unicode text. No activate, no focus; agent sequences those explicitly.")

    @OptionGroup var target: TargetOptions

    @Argument(help: "Text to type.")
    var text: String

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
        try target.assertNoWindowFilter(command: "type")
        let resolved: ResolvedTarget? = target.hasAppSelector
            ? try TargetResolver.resolve(target) : nil

        // Snapshot the target element *before* typing. We re-read its
        // AXValue post-type to confirm the keystrokes actually landed,
        // since AXFocusedUIElement can move during typing (submit-on-
        // enter, autocomplete stealing focus).
        let preSnapshot = resolved.flatMap { AXInspector.focusedSnapshot(pid: $0.pid) }

        if !noOverlay {
            OverlayClient.notify(.pulse(.init(at: nil, label: "type", app: resolved?.app.localizedName)))
        }
        try Input.type(text, toPid: resolved?.pid)

        let verify: VerifyJSON?
        let hint: String?
        if let r = resolved {
            let postFocus = AXInspector.focusedSummary(pid: r.pid)
            let typeCheck: VerifyJSON.TypeCheck?
            if let pre = preSnapshot {
                let postValue = AXInspector.currentValue(of: pre.element)
                let changed = postValue != pre.value
                let landed = postValue.map { $0.contains(text) } ?? false
                let stable = postFocus?.role == pre.role && postFocus?.title == pre.title
                typeCheck = VerifyJSON.TypeCheck(
                    preRole: pre.role, postRole: postFocus?.role,
                    preValue: pre.value, postValue: postValue,
                    valueChanged: changed, textLanded: landed,
                    focusStable: stable)
            } else {
                typeCheck = nil
            }
            verify = VerifyJSON(
                focusedAxPath: nil,
                focusedRole: postFocus?.role,
                focusedTitle: postFocus?.title,
                cursor: nil,
                typeCheck: typeCheck)
            hint = Self.buildTypeHint(typeCheck: typeCheck, postFocus: postFocus)
        } else {
            verify = nil
            hint = nil
        }
        try CLIOut.ok(
            command: "type",
            target: resolved.map { TargetJSON(resolved: $0) },
            result: TypeResult(length: text.count),
            verify: verify, hint: hint)
    }

    private static func buildTypeHint(
        typeCheck: VerifyJSON.TypeCheck?,
        postFocus: (role: String?, title: String?)?
    ) -> String? {
        guard let tc = typeCheck else {
            // No snapshot = no focused element at start = nothing to diff.
            // Still worth flagging when nothing is focused post-type either.
            if postFocus?.role == nil {
                return "No focused element observed; text likely went nowhere. Call `kagete focus --ax-path …` first."
            }
            return nil
        }
        if tc.textLanded { return nil }
        if !tc.focusStable {
            return "Focus moved during type (role \(tc.preRole ?? "?") → \(tc.postRole ?? "?")). Common on submit-on-enter or autocomplete stealing focus. Check the new target state."
        }
        if tc.valueChanged {
            return "Target value changed but does not contain the typed text. The app may have transformed, truncated, or auto-corrected the input."
        }
        return "Target value did not change. Keystrokes likely didn't land in the focused element (custom-drawn input that doesn't surface AXValue, or a read-only field)."
    }
}

/// Background-capable text writer. `type` synthesizes HID keystrokes and
/// therefore requires the target app to hold keyboard focus — unavoidable
/// focus theft from whatever the user was doing. `set-value` takes the AX
/// attribute path instead: `AXUIElementSetAttributeValue(kAXValueAttribute)`
/// writes straight into the element's backing store, so the user's frontmost
/// app keeps focus, the cursor does not move, and no keyboard events leak.
/// Trade-off: only works on elements whose `AXValue` is settable — plain
/// text fields, text areas, search fields, sometimes combo boxes. Custom
/// web inputs / Electron DOM fields route through the DOM event loop and
/// ignore this path; fall back to click + type there.
struct SetValue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-value",
        abstract: "Write text into an AX element without stealing focus. Background alternative to focus + type.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "AX path of the element to write.")
    var axPath: String

    @Argument(help: "Text to set as the element's AXValue.")
    var text: String

    @Flag(name: .long, help: "Skip the awareness overlay for this command.")
    var noOverlay: Bool = false

    @Flag(name: .long, help: "Print only a terse one-line summary on success instead of the JSON envelope.")
    var textOutput: Bool = false

    struct SetValueResult: Codable {
        let axPath: String
        let role: String?
        let title: String?
        let length: Int
        let valueSet: Bool
        let valueMatches: Bool
        let preValue: String?
        let postValue: String?
    }

    func run() async throws {
        do {
            try await runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                SetValueResult.self, command: "set-value",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        let resolvedTarget = try TargetResolver.resolve(target)

        let el = try AXInspector.locate(
            pid: resolvedTarget.pid,
            windowFilter: resolvedTarget.windowFilter,
            axPath: axPath)
        let elementBundle = AXInspector.bundle(for: el)
        let preValue = AXInspector.currentValue(of: el)

        guard AXInspector.isAttributeSettable(el, attribute: kAXValueAttribute) else {
            throw KageteError.failure(
                "AX value not settable on \(axPath) (role=\(elementBundle.role ?? "?")). The element does not expose a writable AXValue. Use `focus` + `type`, or pick a different axPath that targets the inner text input.")
        }

        if !noOverlay {
            OverlayClient.notify(.pulse(.init(
                at: nil,
                label: "set-value",
                app: resolvedTarget.app.localizedName)))
        }

        let err = AXInspector.setStringValue(el, to: text)
        guard err == .success else {
            throw KageteError.failure(
                "AX write failed on \(axPath) (AXError \(err.rawValue)). The element advertises a writable AXValue but the app rejected the write. Common on validated fields or inputs that require real user interaction.")
        }

        let postValue = AXInspector.currentValue(of: el)
        let valueMatches = postValue == text

        let result = SetValueResult(
            axPath: axPath,
            role: elementBundle.role,
            title: elementBundle.title,
            length: text.count,
            valueSet: true,
            valueMatches: valueMatches,
            preValue: preValue,
            postValue: postValue)
        let hint: String? = valueMatches
            ? nil
            : "Write succeeded at the AX layer but the element's post-value differs from the input. The app may have reformatted, truncated, or silently ignored the write (common for fields that require a companion key event to commit)."

        if textOutput {
            let state = valueMatches ? "matched" : "mismatch"
            print("set-value: wrote \(text.count) chars to \(axPath): \(state)")
            return
        }

        try CLIOut.ok(
            command: "set-value",
            target: TargetJSON(resolved: resolvedTarget),
            result: result, verify: nil, hint: hint)
    }
}

/// `kagete key` — synthesize a single key combo. No auto-activate; agent
/// calls `activate` first when the combo routes through the app's menu
/// bar (NSMenu shortcuts usually require frontmost). PID-targeted when a
/// target is resolved, HID tap otherwise.
struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Send a keyboard combo, e.g. cmd+s, shift+tab, f12. No activate.")

    @OptionGroup var target: TargetOptions

    @Argument(help: "Key combo, e.g. \"cmd+shift+4\".")
    var combo: String

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
        try target.assertNoWindowFilter(command: "key")
        let resolved: ResolvedTarget? = target.hasAppSelector
            ? try TargetResolver.resolve(target) : nil
        if !noOverlay {
            OverlayClient.notify(.pulse(.init(at: nil, label: "key \(combo)", app: resolved?.app.localizedName)))
        }
        let parsed = try KeyCodes.parse(combo)
        try Input.key(parsed, toPid: resolved?.pid)

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
        try target.assertNoWindowFilter(command: "scroll")
        let resolved: ResolvedTarget? = target.hasAppSelector
            ? try TargetResolver.resolve(target) : nil
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

        let resolved: ResolvedTarget? = hasTargetFlags
            ? try TargetResolver.resolve(target) : nil

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
        abstract: "Tell the awareness overlay the agent is done. Shows ✓ and returns control.")

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
            : "AX raise did not change focus. Another app may be holding it (e.g. CleanShot X recorder). Retry `activate --method both`."
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
        abstract: "Internal. The overlay helper process (not for direct use).",
        shouldDisplay: false)

    func run() async throws {
        // Pin resultType to Void so the compiler doesn't infer MainActor.run<Never>
        // and then warn that the await statement "will never be executed" — the
        // Never-returning daemon is intentional (it installs its own NSApp
        // runloop and terminates the process via exit).
        await MainActor.run(resultType: Void.self) {
            OverlayDaemon.run()
        }
    }
}
