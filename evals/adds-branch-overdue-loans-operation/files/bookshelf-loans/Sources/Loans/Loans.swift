import ArgumentParser

@main
struct Loans: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "loans",
        abstract: "The Bookshelf loans service",
        subcommands: [
            Serve.self,
            Migrate.self,
            BuildIndexes.self,
        ],
        defaultSubcommand: Serve.self
    )
}
