import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

enum KageteError: Error, CustomStringConvertible {
    case notTrusted(String)
    case notFound(String)
    case ambiguous(String)
    case invalidArgument(String)
    case failure(String)

    var description: String {
        switch self {
        case .notTrusted(let s): return s
        case .notFound(let s): return s
        case .ambiguous(let s): return s
        case .invalidArgument(let s): return s
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

    var hasAppSelector: Bool {
        bundle != nil || app != nil || pid != nil
    }
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

/// Machine-readable error codes for agent branching. The string raw value is
/// the stable contract — do not rename without a version bump.
enum ErrorCode: String, Codable {
    case axElementNotFound = "AX_ELEMENT_NOT_FOUND"
    case axNoFrame = "AX_NO_FRAME"
    case permissionDenied = "PERMISSION_DENIED"
    case invalidArgument = "INVALID_ARGUMENT"
    case targetNotFound = "TARGET_NOT_FOUND"
    case ambiguousTarget = "AMBIGUOUS_TARGET"
    case sckTimeout = "SCK_TIMEOUT"
    case internalError = "INTERNAL"
}

struct ErrorJSON: Codable {
    let code: ErrorCode
    let message: String
    let retryable: Bool
    let hint: String?
}

struct TargetJSON: Codable {
    let pid: Int32?
    let app: String?
    let bundle: String?
    let window: String?

    init(resolved: ResolvedTarget) {
        self.pid = resolved.pid
        self.app = resolved.app.localizedName
        self.bundle = resolved.app.bundleIdentifier
        self.window = resolved.windowFilter
    }
}

/// Uniform response envelope emitted on stdout for every command. Success and
/// failure share the same shape so agents can branch on `ok` and — on error —
/// on `error.code`, without string-matching messages.
struct Envelope<Result: Codable>: Codable {
    let ok: Bool
    let command: String
    let target: TargetJSON?
    let result: Result?
    let verify: VerifyJSON?
    let hint: String?
    let error: ErrorJSON?

    static func success(
        command: String, target: TargetJSON?, result: Result,
        verify: VerifyJSON? = nil, hint: String? = nil
    ) -> Self {
        .init(ok: true, command: command, target: target, result: result,
              verify: verify, hint: hint, error: nil)
    }

    static func failure(
        command: String, target: TargetJSON? = nil, error: ErrorJSON
    ) -> Envelope<Result> {
        .init(ok: false, command: command, target: target, result: nil,
              verify: nil, hint: nil, error: error)
    }
}

struct VerifyJSON: Codable {
    let focusedAxPath: String?
    let focusedRole: String?
    let focusedTitle: String?
    let cursor: PointJSON?
}

extension KageteError {
    /// Classify a thrown KageteError into a stable ErrorCode + retryable flag.
    var asErrorJSON: ErrorJSON {
        switch self {
        case .notTrusted(let s):
            return ErrorJSON(code: .permissionDenied, message: s,
                             retryable: false,
                             hint: "Run `kagete doctor --prompt` and grant the listed permission.")
        case .notFound(let s):
            let code: ErrorCode = s.contains("No AX element") ? .axElementNotFound : .targetNotFound
            return ErrorJSON(code: code, message: s, retryable: false, hint: nil)
        case .ambiguous(let s):
            return ErrorJSON(code: .ambiguousTarget, message: s,
                             retryable: false,
                             hint: "Narrow the target with --pid or --bundle.")
        case .invalidArgument(let s):
            return ErrorJSON(code: .invalidArgument, message: s,
                             retryable: false, hint: nil)
        case .failure(let s):
            let code: ErrorCode
            if s.contains("ScreenCaptureKit timed out") { code = .sckTimeout }
            else if s.contains("no resolvable frame") { code = .axNoFrame }
            else { code = .internalError }
            return ErrorJSON(code: code, message: s,
                             retryable: code == .sckTimeout, hint: nil)
        }
    }
}

/// Emit success/failure envelopes with a single call site. `ok` writes the
/// success envelope to stdout; `fail` writes the failure envelope to stdout,
/// a short human line to stderr, then exits non-zero. Callers wrap `run()` in
/// a do/catch so uncaught KageteError routes through `fail`.
enum CLIOut {
    static func ok<R: Codable>(
        command: String, target: TargetJSON? = nil,
        result: R, verify: VerifyJSON? = nil, hint: String? = nil
    ) throws {
        let env = Envelope<R>.success(
            command: command, target: target, result: result,
            verify: verify, hint: hint)
        try JSON.print(env)
    }

    static func fail<R: Codable>(
        _ resultType: R.Type = EmptyResult.self,
        command: String, target: TargetJSON? = nil, error: KageteError
    ) throws -> Never {
        let env: Envelope<R> = .failure(
            command: command, target: target, error: error.asErrorJSON)
        try JSON.print(env)
        FileHandle.standardError.write(Data("kagete \(command): \(error.description)\n".utf8))
        throw ExitCode(1)
    }
}

struct EmptyResult: Codable {}
