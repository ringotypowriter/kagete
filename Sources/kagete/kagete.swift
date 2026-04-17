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
            Screenshot.self,
            Click.self,
            TypeText.self,
            Key.self,
            Scroll.self,
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
        abstract: "Dump the AX element tree of a target window as JSON.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Maximum tree depth to descend.")
    var maxDepth: Int = 12

    func run() async throws {
        let resolved = try TargetResolver.resolve(target)
        let node = try AXInspector.inspect(
            pid: resolved.pid, windowFilter: resolved.windowFilter, maxDepth: maxDepth)
        try JSON.print(node)
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a PNG screenshot of the target window.")

    @OptionGroup var target: TargetOptions

    @Option(name: [.customShort("o"), .long], help: "Output PNG path.")
    var output: String

    func run() async throws {
        let resolved = try TargetResolver.resolve(target)
        let url = URL(fileURLWithPath: output).absoluteURL
        try await Capture.screenshot(
            pid: resolved.pid, windowFilter: resolved.windowFilter, output: url)
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

    func run() async throws {
        guard let mb = MouseButton(rawValue: button.lowercased()) else {
            throw KageteError.failure("Unknown --button \(button). Use left/right/middle.")
        }

        let point: CGPoint
        if let ax = axPath {
            let resolved = try TargetResolver.resolve(target)
            if activate {
                resolved.app.activate()
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            let el = try AXInspector.locate(
                pid: resolved.pid, windowFilter: resolved.windowFilter, axPath: ax)
            guard let center = AXInspector.screenCenter(of: el) else {
                throw KageteError.failure("Element at \(ax) has no resolvable frame.")
            }
            point = center
        } else if let cx = x, let cy = y {
            point = CGPoint(x: cx, y: cy)
        } else {
            throw KageteError.failure("Provide --ax-path (with --app/--bundle/--pid) or --x/--y.")
        }

        try Input.click(at: point, button: mb, count: count)
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

    func run() async throws {
        if target.app != nil || target.bundle != nil || target.pid != nil {
            let resolved = try TargetResolver.resolve(target)
            if activate {
                resolved.app.activate()
                try await Task.sleep(nanoseconds: 150_000_000)
            }
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

    func run() async throws {
        if target.app != nil || target.bundle != nil || target.pid != nil {
            let resolved = try TargetResolver.resolve(target)
            if activate {
                resolved.app.activate()
                try await Task.sleep(nanoseconds: 150_000_000)
            }
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

    func run() async throws {
        if target.app != nil || target.bundle != nil || target.pid != nil {
            let resolved = try TargetResolver.resolve(target)
            if activate {
                resolved.app.activate()
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        try Input.scroll(dx: dx, dy: dy, lines: !pixels)
    }
}
