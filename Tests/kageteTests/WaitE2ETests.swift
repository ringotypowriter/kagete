import Foundation
import Testing
@testable import kagete

/// End-to-end tests that spawn the built `kagete` binary as a subprocess and
/// assert on the JSON envelope + exit code contract. These cover the argument
/// surface and the `--ms` sleep mode — anything deeper (real AX polling,
/// window appear/vanish) requires Accessibility permission on the test-runner
/// process and is better exercised by manual smoke tests.
@Suite struct WaitEndToEndTests {
    struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Walk up from this source file until we find `.build/debug/kagete`.
    /// `swift test` always builds the product first, so the binary is
    /// guaranteed to be present by the time tests run.
    static let kageteBinary: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir
                .appendingPathComponent(".build")
                .appendingPathComponent("debug")
                .appendingPathComponent("kagete")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("could not locate .build/debug/kagete — run `swift build` first.")
    }()

    private func runKagete(_ args: [String]) throws -> Run {
        let proc = Process()
        proc.executableURL = Self.kageteBinary
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Run(status: proc.terminationStatus, stdout: out, stderr: err)
    }

    private func decodeEnvelope(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("stdout was not a JSON object:\n\(json)")
            return [:]
        }
        return obj
    }

    // --- --ms mode ---

    @Test func msTextModePrintsOneLinerAndExitsZero() throws {
        let r = try runKagete(["wait", "--ms", "50", "--text"])
        #expect(r.status == 0)
        #expect(r.stdout.contains("wait ms:"))
        #expect(r.stdout.contains("slept"))
        #expect(r.stderr.isEmpty)
    }

    @Test func msJsonModeEmitsEnvelope() throws {
        let start = Date()
        let r = try runKagete(["wait", "--ms", "200"])
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.status == 0)
        // The subprocess itself blocks for at least ~200ms.
        #expect(elapsed >= 0.19)

        let env = try decodeEnvelope(r.stdout)
        #expect(env["ok"] as? Bool == true)
        #expect(env["command"] as? String == "wait")
        let result = env["result"] as? [String: Any] ?? [:]
        #expect(result["mode"] as? String == "ms")
        #expect(result["vanish"] as? Bool == false)
        #expect(result["pollCount"] as? Int == 0)
        if let ms = result["elapsedMs"] as? Int {
            #expect(ms >= 200)
        } else {
            Issue.record("elapsedMs missing or wrong type in \(result)")
        }
    }

    // --- Argument validation ---

    @Test func rejectsMissingMode() throws {
        let r = try runKagete(["wait"])
        #expect(r.status == 1)
        let env = try decodeEnvelope(r.stdout)
        #expect(env["ok"] as? Bool == false)
        let error = env["error"] as? [String: Any] ?? [:]
        #expect(error["code"] as? String == "INVALID_ARGUMENT")
        #expect(error["retryable"] as? Bool == false)
        // Short human line goes to stderr as well.
        #expect(r.stderr.contains("kagete wait:"))
    }

    @Test func rejectsMultipleModes() throws {
        let r = try runKagete([
            "wait", "--ms", "100",
            "--role", "AXButton", "--app", "Finder",
        ])
        #expect(r.status == 1)
        let env = try decodeEnvelope(r.stdout)
        let error = env["error"] as? [String: Any] ?? [:]
        #expect(error["code"] as? String == "INVALID_ARGUMENT")
        #expect((error["message"] as? String ?? "").contains("Multiple wait modes"))
    }

    @Test func rejectsNegativeMs() throws {
        // `--ms=-5` form — space-separated `--ms -5` is ambiguous with a flag
        // to ArgumentParser and gets rejected at the parser layer (exit 64).
        let r = try runKagete(["wait", "--ms=-5"])
        #expect(r.status == 1)
        let env = try decodeEnvelope(r.stdout)
        let error = env["error"] as? [String: Any] ?? [:]
        #expect(error["code"] as? String == "INVALID_ARGUMENT")
        #expect((error["message"] as? String ?? "").contains("--ms"))
    }

    @Test func rejectsVanishWithMs() throws {
        let r = try runKagete(["wait", "--ms", "100", "--vanish"])
        #expect(r.status == 1)
        let env = try decodeEnvelope(r.stdout)
        let error = env["error"] as? [String: Any] ?? [:]
        #expect(error["code"] as? String == "INVALID_ARGUMENT")
        #expect((error["message"] as? String ?? "").contains("--vanish"))
    }

    @Test func rejectsAxPathWithoutTarget() throws {
        let r = try runKagete(["wait", "--ax-path", "/AXWindow/AXButton"])
        #expect(r.status == 1)
        let env = try decodeEnvelope(r.stdout)
        let error = env["error"] as? [String: Any] ?? [:]
        #expect(error["code"] as? String == "INVALID_ARGUMENT")
        #expect((error["message"] as? String ?? "").contains("--ax-path"))
    }

    @Test func rejectsElementFiltersWithoutTarget() throws {
        let r = try runKagete(["wait", "--role", "AXButton"])
        #expect(r.status == 1)
        let env = try decodeEnvelope(r.stdout)
        let error = env["error"] as? [String: Any] ?? [:]
        #expect(error["code"] as? String == "INVALID_ARGUMENT")
        #expect((error["message"] as? String ?? "").contains("Element filters require"))
    }

    // --- Target resolution ---

    @Test func unknownAppYieldsTargetNotFound() throws {
        let r = try runKagete([
            "wait", "--app", "NonExistentApp_ZZZ_42",
            "--window-present", "--timeout", "100",
        ])
        #expect(r.status == 1)
        let env = try decodeEnvelope(r.stdout)
        #expect(env["ok"] as? Bool == false)
        let error = env["error"] as? [String: Any] ?? [:]
        #expect(error["code"] as? String == "TARGET_NOT_FOUND")
    }

    // --- Envelope contract (shape checks that don't depend on AX permissions) ---

    @Test func successEnvelopeShapeForMs() throws {
        let r = try runKagete(["wait", "--ms", "10"])
        let env = try decodeEnvelope(r.stdout)
        // The envelope schema is a stable contract for agent consumers.
        #expect(env.keys.contains("ok"))
        #expect(env.keys.contains("command"))
        // Failure-only fields must be absent (or null) on success.
        if let errVal = env["error"] {
            #expect(errVal is NSNull)
        }
    }

    @Test func failureEnvelopeShapeForInvalidArg() throws {
        let r = try runKagete(["wait", "--ms=-1"])
        let env = try decodeEnvelope(r.stdout)
        #expect(env["ok"] as? Bool == false)
        let error = env["error"] as? [String: Any] ?? [:]
        #expect(error.keys.contains("code"))
        #expect(error.keys.contains("message"))
        #expect(error.keys.contains("retryable"))
    }
}
