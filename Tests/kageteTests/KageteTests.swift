import Testing
@testable import kagete

@Suite struct KageteTests {
    @Test func defaultGreeting() throws {
        var cmd = try Kagete.parse([])
        #expect(cmd.name == "world")
    }

    @Test func customName() throws {
        let cmd = try Kagete.parse(["leader"])
        #expect(cmd.name == "leader")
    }
}
