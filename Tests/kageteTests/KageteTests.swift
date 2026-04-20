import CoreGraphics
import Foundation
import Testing
@testable import kagete

@Suite struct PathSegmentTests {
    @Test func roleOnly() {
        #expect(AXInspector.pathSegment(role: "AXButton", title: nil, identifier: nil) == "AXButton")
    }

    @Test func titlePreferred() {
        let seg = AXInspector.pathSegment(role: "AXButton", title: "OK", identifier: nil)
        #expect(seg == "AXButton[title=\"OK\"]")
    }

    @Test func identifierWinsOverTitle() {
        let seg = AXInspector.pathSegment(role: "AXButton", title: "OK", identifier: "submit-btn")
        #expect(seg == "AXButton[id=\"submit-btn\"]")
    }

    @Test func escapesQuotesAndBackslashes() {
        let seg = AXInspector.pathSegment(role: "AXTextField", title: "say \"hi\"", identifier: nil)
        #expect(seg == "AXTextField[title=\"say \\\"hi\\\"\"]")
    }

    @Test func fallbackRoleWhenMissing() {
        #expect(AXInspector.pathSegment(role: nil, title: nil, identifier: nil) == "AXElement")
    }
}

@Suite struct BoundsJSONTests {
    @Test func encodesRect() throws {
        let b = BoundsJSON(CGRect(x: 10, y: 20, width: 300, height: 400))
        #expect(b.x == 10)
        #expect(b.y == 20)
        #expect(b.width == 300)
        #expect(b.height == 400)
    }
}

@Suite struct WaitModeResolverTests {
    // Helpers --------------------------------------------------------------

    private func resolve(
        hasAppSelector: Bool = false,
        windowTitleFilter: String? = nil,
        axPath: String? = nil,
        pathValueContains: String? = nil,
        criteria: FindCriteria = FindCriteria(),
        windowPresent: Bool = false,
        ms: Int? = nil,
        vanish: Bool = false
    ) throws -> Wait.Mode {
        try Wait.resolveMode(
            hasAppSelector: hasAppSelector,
            windowTitleFilter: windowTitleFilter,
            axPath: axPath,
            pathValueContains: pathValueContains,
            elementCriteria: criteria,
            windowPresent: windowPresent,
            ms: ms, vanish: vanish)
    }

    private func expectInvalidArgument(
        messageContains needle: String? = nil,
        _ block: () throws -> Wait.Mode,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try block()
            Issue.record(
                "expected KageteError.invalidArgument, got a Mode",
                sourceLocation: sourceLocation)
        } catch let err as KageteError {
            guard case .invalidArgument(let msg) = err else {
                Issue.record(
                    "expected invalidArgument, got \(err)",
                    sourceLocation: sourceLocation)
                return
            }
            if let needle, !msg.contains(needle) {
                Issue.record(
                    "message \"\(msg)\" missing \"\(needle)\"",
                    sourceLocation: sourceLocation)
            }
        } catch {
            Issue.record(
                "expected KageteError, got \(error)",
                sourceLocation: sourceLocation)
        }
    }

    // Mode selection -------------------------------------------------------

    @Test func msModeWithPositiveDelay() throws {
        let mode = try resolve(ms: 250)
        #expect(mode == .ms(250))
    }

    @Test func msModeAcceptsZero() throws {
        let mode = try resolve(ms: 0)
        #expect(mode == .ms(0))
    }

    @Test func axPathWithTargetSelector() throws {
        let mode = try resolve(hasAppSelector: true, axPath: "/AXWindow/AXButton")
        #expect(mode == .axPath("/AXWindow/AXButton", valueContains: nil))
    }

    @Test func axPathCarriesValueContains() throws {
        let mode = try resolve(
            hasAppSelector: true, axPath: "/AXWindow/AXTextField",
            pathValueContains: "github.com")
        #expect(mode == .axPath("/AXWindow/AXTextField", valueContains: "github.com"))
    }

    @Test func elementModeFromCriteria() throws {
        var c = FindCriteria()
        c.role = "AXButton"
        c.textContains = "Save"
        let mode = try resolve(hasAppSelector: true, criteria: c)
        #expect(mode == .element(c))
    }

    @Test func elementModeAllowsTextContainsWithSubrole() throws {
        var c = FindCriteria()
        c.subrole = "AXCloseButton"
        c.textContains = "Save"
        let mode = try resolve(hasAppSelector: true, criteria: c)
        #expect(mode == .element(c))
    }

    // The "query echoes in the search UI" guard: without a type filter,
    // wait would match the text field the query was typed into and return
    // in ~50 ms on the first poll. The guard is enforced at the binary
    // layer, not just documented, because docs are soft and agents ignore
    // them.
    @Test func textContainsWithoutRoleOrSubroleIsRejected() {
        var c = FindCriteria()
        c.textContains = "Welcome to New York"
        expectInvalidArgument(messageContains: "--text-contains") {
            try resolve(hasAppSelector: true, criteria: c)
        }
    }

    @Test func textContainsWithEnabledOnlyStillRejected() {
        var c = FindCriteria()
        c.textContains = "Continue"
        c.enabledOnly = true
        expectInvalidArgument(messageContains: "--text-contains") {
            try resolve(hasAppSelector: true, criteria: c)
        }
    }

    // `--value-contains` in element mode used to piggy-back on the same
    // flag as path mode but was silently dropped after the filter strip.
    // The guard makes the drop loud: any non-path mode carrying
    // `--value-contains` parse-fails with a pointer to `--text-contains`.

    @Test func valueContainsWithoutAxPathInElementModeIsRejected() {
        var c = FindCriteria()
        c.role = "AXTextField"
        expectInvalidArgument(messageContains: "--value-contains") {
            try resolve(
                hasAppSelector: true,
                pathValueContains: "github.com",
                criteria: c)
        }
    }

    @Test func valueContainsWithoutAxPathInMsModeIsRejected() {
        expectInvalidArgument(messageContains: "--value-contains") {
            try resolve(pathValueContains: "anything", ms: 250)
        }
    }

    @Test func valueContainsWithAxPathStillFlows() throws {
        let mode = try resolve(
            hasAppSelector: true,
            axPath: "/AXWindow/AXTextField",
            pathValueContains: "github.com")
        #expect(mode == .axPath("/AXWindow/AXTextField", valueContains: "github.com"))
    }

    @Test func windowPresentWithAppSelector() throws {
        let mode = try resolve(hasAppSelector: true, windowPresent: true)
        #expect(mode == .windowPresent)
    }

    @Test func windowPresentWithOnlyTitleFilter() throws {
        let mode = try resolve(
            hasAppSelector: false,
            windowTitleFilter: "Downloads",
            windowPresent: true)
        #expect(mode == .windowPresent)
    }

    // Validation errors ----------------------------------------------------

    @Test func rejectsNoMode() {
        expectInvalidArgument(messageContains: "No wait mode selected") {
            try self.resolve()
        }
    }

    @Test func rejectsMultipleModes() {
        var c = FindCriteria()
        c.role = "AXButton"
        expectInvalidArgument(messageContains: "Multiple wait modes") {
            try self.resolve(hasAppSelector: true, criteria: c, ms: 100)
        }
    }

    @Test func rejectsAxPathPlusWindowPresent() {
        expectInvalidArgument(messageContains: "Multiple wait modes") {
            try self.resolve(
                hasAppSelector: true, axPath: "/AXWindow",
                windowPresent: true)
        }
    }

    @Test func rejectsNegativeMs() {
        expectInvalidArgument(messageContains: "--ms") {
            try self.resolve(ms: -1)
        }
    }

    @Test func rejectsVanishWithMs() {
        expectInvalidArgument(messageContains: "--vanish") {
            try self.resolve(ms: 100, vanish: true)
        }
    }

    @Test func rejectsAxPathWithoutTarget() {
        expectInvalidArgument(messageContains: "--ax-path") {
            try self.resolve(hasAppSelector: false, axPath: "/AXWindow/AXButton")
        }
    }

    @Test func rejectsElementModeWithoutTarget() {
        var c = FindCriteria()
        c.role = "AXButton"
        expectInvalidArgument(messageContains: "Element filters require") {
            try self.resolve(hasAppSelector: false, criteria: c)
        }
    }

    @Test func rejectsWindowPresentWithoutAnySelector() {
        expectInvalidArgument(messageContains: "--window-present") {
            try self.resolve(hasAppSelector: false, windowPresent: true)
        }
    }
}

/// PID-targeted primitives (`type`, `key`, `click-at`, `scroll`) route
/// events to the resolved process PID; `--window` never travels into the
/// post. Accepting it silently would leak a lie into the response
/// envelope (target.window populated as if the filter was honored). The
/// guard fires before any side-effect work.
@Suite struct TargetOptionsWindowGuardTests {
    @Test func allowsMissingWindow() throws {
        let opts = try TargetOptions.parse(["--app", "Safari"])
        try opts.assertNoWindowFilter(command: "type")
    }

    @Test func rejectsWindowWithCommandNameInMessage() {
        do {
            let opts = try TargetOptions.parse(
                ["--app", "Safari", "--window", "GitHub"])
            try opts.assertNoWindowFilter(command: "type")
            Issue.record("expected KageteError.invalidArgument")
        } catch let err as KageteError {
            guard case .invalidArgument(let msg) = err else {
                Issue.record("expected invalidArgument, got \(err)")
                return
            }
            #expect(msg.contains("--window"))
            #expect(msg.contains("type"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func commandLabelIsThreadedThroughMessage() {
        do {
            let opts = try TargetOptions.parse(
                ["--app", "Safari", "--window", "GitHub"])
            try opts.assertNoWindowFilter(command: "click-at")
            Issue.record("expected throw")
        } catch let err as KageteError {
            guard case .invalidArgument(let msg) = err else {
                Issue.record("expected invalidArgument, got \(err)")
                return
            }
            #expect(msg.contains("click-at"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite struct FindCriteriaTests {
    @Test func emptyCriteriaHasNoFilter() {
        let c = FindCriteria()
        #expect(!c.hasAnyFilter)
    }

    @Test func roleCountsAsFilter() {
        var c = FindCriteria()
        c.role = "AXButton"
        #expect(c.hasAnyFilter)
    }

    @Test func booleanFlagsCountAsFilter() {
        var c = FindCriteria()
        c.enabledOnly = true
        #expect(c.hasAnyFilter)
    }
}

@Suite struct KeyCodeTests {
    @Test func singleLetter() throws {
        let combo = try KeyCodes.parse("s")
        #expect(combo.keyCode == 1)
        #expect(combo.flags == [])
    }

    @Test func cmdS() throws {
        let combo = try KeyCodes.parse("cmd+s")
        #expect(combo.keyCode == 1)
        #expect(combo.flags.contains(.maskCommand))
    }

    @Test func cmdShiftFour() throws {
        let combo = try KeyCodes.parse("cmd+shift+4")
        #expect(combo.keyCode == 21)
        #expect(combo.flags.contains(.maskCommand))
        #expect(combo.flags.contains(.maskShift))
    }

    @Test func namedKey() throws {
        let combo = try KeyCodes.parse("return")
        #expect(combo.keyCode == 36)
        let esc = try KeyCodes.parse("esc")
        #expect(esc.keyCode == 53)
        let f12 = try KeyCodes.parse("f12")
        #expect(f12.keyCode == 111)
    }

    @Test func aliasesAgree() throws {
        let a = try KeyCodes.parse("cmd+s")
        let b = try KeyCodes.parse("command+s")
        let c = try KeyCodes.parse("meta+s")
        #expect(a == b)
        #expect(b == c)
    }

    @Test func rejectsUnknownKey() {
        #expect(throws: KageteError.self) {
            _ = try KeyCodes.parse("cmd+bogus")
        }
    }

    @Test func rejectsMultipleBaseKeys() {
        #expect(throws: KageteError.self) {
            _ = try KeyCodes.parse("a+b")
        }
    }

    @Test func parsesModifiersOnly() throws {
        let flags = try KeyCodes.parseModifiers("shift+cmd")
        #expect(flags.contains(.maskShift))
        #expect(flags.contains(.maskCommand))
    }

    @Test func emptyModifierStringYieldsNoFlags() throws {
        let flags = try KeyCodes.parseModifiers("")
        #expect(flags == [])
    }

    @Test func modifierParserRejectsUnknown() {
        #expect(throws: KageteError.self) {
            _ = try KeyCodes.parseModifiers("shift+bogus")
        }
    }
}

@Suite struct ActivatorMethodTests {
    // The `.auto` fallback was removed: activation methods are explicit.
    // `Method(rawValue:)` is the new contract, exercised here so a rename
    // of the raw values immediately breaks the test (the CLI depends on
    // these strings for `kagete activate --method …`).

    @Test func recognizedMethodsParse() {
        #expect(Activator.Method(rawValue: "app") == .app)
        #expect(Activator.Method(rawValue: "ax") == .ax)
        #expect(Activator.Method(rawValue: "both") == .both)
    }

    @Test func unknownMethodReturnsNil() {
        #expect(Activator.Method(rawValue: "auto") == nil)
        #expect(Activator.Method(rawValue: "bogus") == nil)
        #expect(Activator.Method(rawValue: "") == nil)
    }
}

@Suite struct ActionAllowlistTests {
    @Test func allowlistIncludesExpectedActions() {
        #expect(Action.allowed.contains("AXShowMenu"))
        #expect(Action.allowed.contains("AXIncrement"))
        #expect(Action.allowed.contains("AXDecrement"))
        #expect(Action.allowed.contains("AXPick"))
        #expect(Action.allowed.contains("AXConfirm"))
        #expect(Action.allowed.contains("AXCancel"))
    }

    @Test func allowlistExcludesPressAndScrollTo() {
        // These each have their own dedicated verb — `press` and `scroll-to`.
        // If they leaked into the generic `action` allowlist, we'd have two
        // ways to spell the same thing, which is exactly the "agent guesses
        // which verb" problem we're removing.
        #expect(!Action.allowed.contains("AXPress"))
        #expect(!Action.allowed.contains("AXScrollToVisible"))
    }
}

@Suite struct InputMouseEventTests {
    @Test func mouseClickEventCarriesClickStateAndEventNumber() throws {
        let source = try Input.makeEventSource()
        let event = try #require(Input.makeMouseClickEvent(
            source: source,
            type: .leftMouseDown,
            point: CGPoint(x: 10, y: 20),
            button: .left,
            clickState: 2,
            eventNumber: 42,
            pressure: 1))

        #expect(event.getIntegerValueField(.mouseEventClickState) == 2)
        #expect(event.getIntegerValueField(.mouseEventNumber) == 42)
        #expect(event.getDoubleValueField(.mouseEventPressure) == 1)
    }

    @Test func mouseClickEventPreservesButtonAndPosition() throws {
        let source = try Input.makeEventSource()
        let point = CGPoint(x: 120, y: 240)
        let event = try #require(Input.makeMouseClickEvent(
            source: source,
            type: .rightMouseUp,
            point: point,
            button: .right,
            clickState: 1,
            eventNumber: 7,
            pressure: 0))

        #expect(event.location.x == point.x)
        #expect(event.location.y == point.y)
        #expect(event.getIntegerValueField(.mouseEventButtonNumber) == Int64(CGMouseButton.right.rawValue))
    }
}

@Suite struct SetValueResultTests {
    @Test func encodesAllFields() throws {
        let result = SetValue.SetValueResult(
            axPath: "/AXWindow/AXTextField[title=\"Name\"]",
            role: "AXTextField",
            title: "Name",
            length: 5,
            valueSet: true,
            valueMatches: true,
            preValue: "",
            postValue: "hello")
        let data = try JSONEncoder().encode(result)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let json = try #require(obj)
        #expect(json["axPath"] as? String == "/AXWindow/AXTextField[title=\"Name\"]")
        #expect(json["role"] as? String == "AXTextField")
        #expect(json["title"] as? String == "Name")
        #expect(json["length"] as? Int == 5)
        #expect(json["valueSet"] as? Bool == true)
        #expect(json["valueMatches"] as? Bool == true)
        #expect(json["preValue"] as? String == "")
        #expect(json["postValue"] as? String == "hello")
    }

    @Test func encodesNullablesWhenMissing() throws {
        let result = SetValue.SetValueResult(
            axPath: "/AXWindow/AXTextField",
            role: nil,
            title: nil,
            length: 0,
            valueSet: true,
            valueMatches: false,
            preValue: nil,
            postValue: nil)
        let data = try JSONEncoder().encode(result)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let json = try #require(obj)
        #expect(json["axPath"] as? String == "/AXWindow/AXTextField")
        #expect(json["valueMatches"] as? Bool == false)
        // Nullable fields serialize absent rather than NSNull under the default
        // JSONEncoder — the contract agents rely on.
        #expect(json["role"] == nil)
        #expect(json["title"] == nil)
        #expect(json["preValue"] == nil)
        #expect(json["postValue"] == nil)
    }
}

@Suite struct SetValueErrorClassificationTests {
    // Sentinels in the error message drive the stable ErrorCode. If the
    // SetValue command's message strings drift, these tests break and
    // `asErrorJSON` silently regresses to `INTERNAL` — which would hide
    // the background-write semantics from every agent on the other side.

    @Test func notSettableMessageClassifiesAsAxNotSettable() {
        let err = KageteError.failure(
            "AX value not settable on /AXWindow/AXStaticText (role=AXStaticText). Fall back to click + type.")
        #expect(err.asErrorJSON.code == .axNotSettable)
        #expect(err.asErrorJSON.retryable == false)
    }

    @Test func writeFailedMessageClassifiesAsAxWriteFailed() {
        let err = KageteError.failure(
            "AX write failed on /AXWindow/AXTextField (AXError -25205).")
        #expect(err.asErrorJSON.code == .axWriteFailed)
        #expect(err.asErrorJSON.retryable == false)
    }

    @Test func unrelatedFailureRemainsInternal() {
        let err = KageteError.failure("Something entirely different went wrong.")
        #expect(err.asErrorJSON.code == .internalError)
    }
}
