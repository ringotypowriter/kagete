import CoreGraphics
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
