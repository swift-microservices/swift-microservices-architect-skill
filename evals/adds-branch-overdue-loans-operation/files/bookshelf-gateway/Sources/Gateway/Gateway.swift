import ArgumentParser

@main
struct Gateway: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gateway",
        abstract: "The Bookshelf public HTTP API",
        subcommands: [
            Serve.self
        ],
        defaultSubcommand: Serve.self
    )
}
