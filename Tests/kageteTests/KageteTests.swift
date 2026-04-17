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
