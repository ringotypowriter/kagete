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

    /// Name of the process that launched kagete — the terminal, IDE, or
    /// agent harness. macOS grants Accessibility and Screen Recording
    /// *per-process* and the effective grant belongs to whichever binary
    /// owns the process tree. So "add kagete to Accessibility" is wrong
    /// advice: the user must grant the permission to *this* process
    /// (Ghostty / iTerm / Terminal / Claude Code / Codex / …). Returns
    /// nil if the parent name can't be read.
    static var hostProcessName: String? {
        let ppid = getppid()
        let proc = Process()
        proc.launchPath = "/bin/ps"
        proc.arguments = ["-o", "comm=", "-p", "\(ppid)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let full = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !full.isEmpty else { return nil }
        // `ps -o comm=` returns the full path on macOS. Take the basename
        // and strip the `.app/Contents/MacOS/...` tail so "Ghostty.app
        // /Contents/MacOS/ghostty" becomes "Ghostty".
        if let appRange = full.range(of: ".app/") {
            let appPath = String(full[..<appRange.upperBound].dropLast())
            return (appPath as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
        }
        return (full as NSString).lastPathComponent
    }

    /// Human-readable "where to grant permission" label, baked into error
    /// messages. Falls back to generic guidance when the parent can't be
    /// identified.
    static var hostLabel: String {
        if let name = hostProcessName, !name.isEmpty {
            return name
        }
        return "the terminal or agent harness running kagete"
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
    case waitTimeout = "WAIT_TIMEOUT"
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
    let typeCheck: TypeCheck?

    init(
        focusedAxPath: String? = nil,
        focusedRole: String? = nil,
        focusedTitle: String? = nil,
        cursor: PointJSON? = nil,
        typeCheck: TypeCheck? = nil
    ) {
        self.focusedAxPath = focusedAxPath
        self.focusedRole = focusedRole
        self.focusedTitle = focusedTitle
        self.cursor = cursor
        self.typeCheck = typeCheck
    }

    /// Post-type verification for the `type` command. `valueChanged` and
    /// `textLanded` are the reliable signals — `focusedRole` before/after
    /// is informational only since focus can move mid-type (form submit,
    /// autocomplete). `textLanded == true` is the only "yes it worked"
    /// signal agents should branch on.
    struct TypeCheck: Codable {
        let preRole: String?
        let postRole: String?
        let preValue: String?
        let postValue: String?
        let valueChanged: Bool
        let textLanded: Bool
        let focusStable: Bool
    }
}

extension KageteError {
    /// Classify a thrown KageteError into a stable ErrorCode + retryable flag.
    var asErrorJSON: ErrorJSON {
        switch self {
        case .notTrusted(let s):
            return ErrorJSON(code: .permissionDenied, message: s,
                             retryable: false,
                             hint: "Run `kagete doctor --prompt` and grant the listed permission to the process that launched kagete (not to kagete itself).")
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
            else if s.contains("wait timed out") { code = .waitTimeout }
            else if s.contains("no resolvable frame") { code = .axNoFrame }
            else { code = .internalError }
            let retryable = (code == .sckTimeout || code == .waitTimeout)
            return ErrorJSON(code: code, message: s,
                             retryable: retryable, hint: nil)
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
