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
