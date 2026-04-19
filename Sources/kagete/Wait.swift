import ApplicationServices
import ArgumentParser
import Foundation

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Poll until an AX element, window, or value appears (or vanishes) — or sleep for a fixed delay.")

    @OptionGroup var target: TargetOptions

    @Option(name: .long, help: "Wait for this exact AX path to resolve (requires --app/--bundle/--pid). Combine with --value-contains to wait for a value to land.")
    var axPath: String?

    @Option(name: .long, help: "Match AX role (e.g. AXButton).")
    var role: String?

    @Option(name: .long, help: "Match AX subrole.")
    var subrole: String?

    @Option(name: .long, help: "Exact title match.")
    var title: String?

    @Option(name: .long, help: "Substring of title (case-insensitive).")
    var titleContains: String?

    @Option(name: [.customLong("id"), .customLong("identifier")], help: "AXIdentifier.")
    var identifier: String?

    @Option(name: .long, help: "Substring of AXDescription (case-insensitive).")
    var descriptionContains: String?

    @Option(name: .long, help: "Substring of AXValue (case-insensitive). Pairs with --ax-path to wait for a specific element's value.")
    var valueContains: String?

    @Flag(name: .long, help: "Only enabled elements.")
    var enabledOnly: Bool = false

    @Flag(name: .long, help: "Only disabled elements.")
    var disabledOnly: Bool = false

    @Flag(name: .long, help: "Wait for a window to appear (combine with --app/--bundle/--pid and/or --window title filter).")
    var windowPresent: Bool = false

    @Option(name: .long, help: "Sleep for N milliseconds, then return. Exclusive with the other modes.")
    var ms: Int?

    @Flag(name: .long, help: "Invert: wait for the condition to become FALSE (element vanishes, window closes, value no longer contains).")
    var vanish: Bool = false

    @Option(name: .long, help: "Total wait budget in milliseconds.")
    var timeout: Int = 5000

    @Option(name: .long, help: "Poll interval in milliseconds.")
    var interval: Int = 150

    @Option(name: .long, help: "Maximum AX tree depth for element searches.")
    var maxDepth: Int = 64

    @Flag(name: .long, help: "Print a terse one-liner instead of the JSON envelope.")
    var text: Bool = false

    struct WaitResult: Codable {
        let mode: String
        let vanish: Bool
        let elapsedMs: Int
        let pollCount: Int
        let hit: AXHit?
        let window: WindowRecord?
    }

    enum Mode: Equatable {
        case ms(Int)
        case axPath(String, valueContains: String?)
        case element(FindCriteria)
        case windowPresent
    }

    func run() async throws {
        do {
            try await runInner()
        } catch let err as KageteError {
            try CLIOut.fail(
                WaitResult.self, command: "wait",
                target: (try? TargetResolver.resolve(target)).map { TargetJSON(resolved: $0) },
                error: err)
        }
    }

    private func runInner() async throws {
        // --value-contains is shared: on path mode it filters the path's
        // value; otherwise it's an element-filter predicate.
        let elementCriteria = FindCriteria(
            role: role, subrole: subrole, title: title,
            titleContains: titleContains, identifier: identifier,
            descriptionContains: descriptionContains,
            valueContains: axPath == nil ? valueContains : nil,
            enabledOnly: enabledOnly, disabledOnly: disabledOnly)
        let mode = try Self.resolveMode(
            hasAppSelector: target.hasAppSelector,
            windowTitleFilter: target.window,
            axPath: axPath,
            pathValueContains: valueContains,
            elementCriteria: elementCriteria,
            windowPresent: windowPresent,
            ms: ms, vanish: vanish)
        let start = DispatchTime.now()

        switch mode {
        case .ms(let n):
            if n > 0 { try await sleepMs(n) }
            try emit(
                mode: "ms", elapsedMs: n, pollCount: 0,
                hit: nil, window: nil, resolved: nil)

        case .axPath(let path, let valueContains):
            let resolved = try TargetResolver.resolve(target)
            let hit = try await pollUntil(start: start) { () -> AXHit? in
                guard let el = try? AXInspector.locate(
                    pid: resolved.pid, windowFilter: resolved.windowFilter, axPath: path)
                else { return nil }
                let b = AXInspector.bundle(for: el)
                if let want = valueContains {
                    let v = b.valueString ?? ""
                    guard v.localizedCaseInsensitiveContains(want) else { return nil }
                }
                return AXHit(
                    role: b.role, subrole: b.subrole,
                    title: b.title, value: b.valueString,
                    description: b.description, identifier: b.identifier,
                    enabled: b.enabled, focused: b.focused,
                    actions: nil, frame: b.frame, axPath: path)
            }
            try emit(
                mode: "path", elapsedMs: elapsedMs(start),
                pollCount: hit.polls, hit: hit.value, window: nil,
                resolved: resolved)

        case .element(let criteria):
            let resolved = try TargetResolver.resolve(target)
            let hit = try await pollUntil(start: start) { () -> AXHit? in
                let hits = (try? AXInspector.find(
                    pid: resolved.pid, windowFilter: resolved.windowFilter,
                    criteria: criteria, limit: 1, maxDepth: maxDepth)) ?? []
                return hits.first
            }
            try emit(
                mode: "element", elapsedMs: elapsedMs(start),
                pollCount: hit.polls, hit: hit.value, window: nil,
                resolved: resolved)

        case .windowPresent:
            // If an app selector is given it must resolve — otherwise the
            // poll would silently fall back to "any window in the system"
            // and mask a typo in --app. Title-only filter is still allowed.
            let resolved: ResolvedTarget?
            if target.hasAppSelector {
                resolved = try TargetResolver.resolve(target)
            } else {
                resolved = nil
            }
            let hit = try await pollUntil(start: start) { () -> WindowRecord? in
                let wins = WindowList.all(filterPid: resolved?.pid)
                if let f = target.window {
                    return wins.first { ($0.title ?? "").localizedCaseInsensitiveContains(f) }
                }
                return wins.first
            }
            try emit(
                mode: "window", elapsedMs: elapsedMs(start),
                pollCount: hit.polls, hit: nil, window: hit.value,
                resolved: resolved)
        }
    }

    /// Pure mode resolver — exposed as a static so unit tests can exercise
    /// every mutually-exclusive path without constructing a `Wait` through
    /// `ArgumentParser`.
    static func resolveMode(
        hasAppSelector: Bool,
        windowTitleFilter: String?,
        axPath: String?,
        pathValueContains: String?,
        elementCriteria: FindCriteria,
        windowPresent: Bool,
        ms: Int?,
        vanish: Bool
    ) throws -> Mode {
        var chosen: [String] = []
        if ms != nil { chosen.append("--ms") }
        if axPath != nil { chosen.append("--ax-path") }
        if windowPresent { chosen.append("--window-present") }
        if elementCriteria.hasAnyFilter { chosen.append("element-filter") }

        guard chosen.count == 1 else {
            if chosen.isEmpty {
                throw KageteError.invalidArgument(
                    "No wait mode selected. Use --ms, --ax-path, --window-present, or element filters (--role / --title / --title-contains / ...).")
            }
            throw KageteError.invalidArgument(
                "Multiple wait modes specified (\(chosen.joined(separator: ", "))) — pick one.")
        }

        if let n = ms {
            guard n >= 0 else { throw KageteError.invalidArgument("--ms must be >= 0.") }
            guard !vanish else { throw KageteError.invalidArgument("--vanish is not meaningful with --ms.") }
            return .ms(n)
        }
        if let path = axPath {
            guard hasAppSelector else {
                throw KageteError.invalidArgument("--ax-path requires --app/--bundle/--pid.")
            }
            return .axPath(path, valueContains: pathValueContains)
        }
        if windowPresent {
            guard hasAppSelector || windowTitleFilter != nil else {
                throw KageteError.invalidArgument("--window-present requires --app/--bundle/--pid or --window.")
            }
            return .windowPresent
        }
        guard hasAppSelector else {
            throw KageteError.invalidArgument("Element filters require --app/--bundle/--pid.")
        }
        return .element(elementCriteria)
    }

    private struct PollHit<T> {
        let value: T?
        let polls: Int
    }

    /// Generic poll loop. On `!vanish` mode: returns the first non-nil probe.
    /// On `vanish`: returns once probe yields nil (value field stays nil).
    /// Throws `KageteError.failure` with "wait timed out" on deadline — mapped
    /// to the WAIT_TIMEOUT error code downstream.
    private func pollUntil<T>(
        start: DispatchTime,
        probe: () -> T?
    ) async throws -> PollHit<T> {
        guard timeout >= 0 else {
            throw KageteError.invalidArgument("--timeout must be >= 0.")
        }
        guard interval > 0 else {
            throw KageteError.invalidArgument("--interval must be > 0.")
        }
        let deadline = start.uptimeNanoseconds &+ UInt64(timeout) * 1_000_000
        var polls = 0
        while true {
            polls += 1
            let observed = probe()
            if vanish {
                if observed == nil { return PollHit(value: nil, polls: polls) }
            } else {
                if let v = observed { return PollHit(value: v, polls: polls) }
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            try await sleepMs(interval)
        }
        let elapsed = elapsedMs(start)
        let kind = vanish ? "vanish" : "appear"
        throw KageteError.failure(
            "wait timed out after \(elapsed)ms (\(polls) polls, mode=\(kind)).")
    }

    private func elapsedMs(_ start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    private func sleepMs(_ n: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, n)) * 1_000_000)
    }

    private func emit(
        mode: String, elapsedMs: Int, pollCount: Int,
        hit: AXHit?, window: WindowRecord?,
        resolved: ResolvedTarget?
    ) throws {
        if text {
            let verdict = vanish ? "vanished" : "appeared"
            let tag = mode == "ms" ? "slept" : verdict
            print("wait \(mode): \(tag) in \(elapsedMs)ms (\(pollCount) polls)")
            return
        }
        let result = WaitResult(
            mode: mode, vanish: vanish,
            elapsedMs: elapsedMs, pollCount: pollCount,
            hit: hit, window: window)
        try CLIOut.ok(
            command: "wait",
            target: resolved.map { TargetJSON(resolved: $0) },
            result: result)
    }
}
