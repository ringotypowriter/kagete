import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

enum KageteError: Error, CustomStringConvertible {
    case notTrusted(String)
    case notFound(String)
    case ambiguous(String)
    case failure(String)

    var description: String {
        switch self {
        case .notTrusted(let s): return s
        case .notFound(let s): return s
        case .ambiguous(let s): return s
        case .failure(let s): return s
        }
    }
}

struct BoundsJSON: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func promptAccessibility() -> Bool {
        // String literal value of kAXTrustedCheckOptionPrompt — avoids Swift 6
        // concurrency diagnostic on the imported C global.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @discardableResult
    static func promptScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

struct TargetOptions: ParsableArguments {
    @Option(name: .long, help: "Bundle identifier, e.g. com.apple.Safari.")
    var bundle: String?

    @Option(name: .long, help: "App name (localized or executable), e.g. Safari.")
    var app: String?

    @Option(name: .long, help: "Process ID.")
    var pid: Int32?

    @Option(name: .long, help: "Window title substring (case-insensitive).")
    var window: String?
}

struct ResolvedTarget {
    let pid: pid_t
    let app: NSRunningApplication
    let windowFilter: String?
}

enum TargetResolver {
    static func resolve(_ opts: TargetOptions) throws -> ResolvedTarget {
        let candidates: [NSRunningApplication]
        if let pid = opts.pid {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw KageteError.notFound("No running app with pid \(pid).")
            }
            candidates = [app]
        } else if let bundle = opts.bundle {
            candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            if candidates.isEmpty {
                throw KageteError.notFound("No running app with bundle id \(bundle).")
            }
        } else if let name = opts.app {
            let lowered = name.lowercased()
            candidates = NSWorkspace.shared.runningApplications.filter { app in
                if app.activationPolicy != .regular && app.activationPolicy != .accessory { return false }
                if app.localizedName?.lowercased() == lowered { return true }
                if app.executableURL?.lastPathComponent.lowercased() == lowered { return true }
                return false
            }
            if candidates.isEmpty {
                throw KageteError.notFound("No running app named \(name).")
            }
        } else {
            throw KageteError.notFound("Specify --app, --bundle, or --pid.")
        }

        if candidates.count > 1 {
            let list = candidates
                .map { "  pid \($0.processIdentifier): \($0.localizedName ?? "?") [\($0.bundleIdentifier ?? "?")]" }
                .joined(separator: "\n")
            throw KageteError.ambiguous("Multiple matches — narrow with --pid or --bundle:\n\(list)")
        }

        let app = candidates[0]
        return ResolvedTarget(pid: app.processIdentifier, app: app, windowFilter: opts.window)
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func print<T: Encodable>(_ value: T) throws {
        let data = try encoder.encode(value)
        if let s = String(data: data, encoding: .utf8) {
            Swift.print(s)
        }
    }
}
