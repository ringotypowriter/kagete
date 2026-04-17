import ArgumentParser

@main
struct Kagete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kagete",
        abstract: "A Swift CLI app.",
        version: "0.1.0"
    )

    @Argument(help: "Name to greet.")
    var name: String = "world"

    func run() throws {
        print("Hello, \(name)!")
    }
}
