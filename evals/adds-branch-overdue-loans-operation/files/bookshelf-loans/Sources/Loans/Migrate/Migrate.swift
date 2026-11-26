import ArgumentParser
import BookshelfPersistence
import Configuration
import Logging
import PersistencePostgres
import PostgresNIO

struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Apply pending database migrations, then exit"
    )

    func run() async throws {
        // MARK: - Configuration
        let config = ConfigReader(providers: [
            EnvironmentVariablesProvider(),
            InMemoryProvider.applicationDefaults,
        ])

        // MARK: - Logging
        let logLevel = config.string(forKey: "logLevel", default: Logger.Level.info)
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = logLevel
            return handler
        }
        let logger = Logger(label: "bookshelf-loans")

        // MARK: - Infrastructure
        let postgresConfig = config.scoped(to: "postgres")
        let ownerPostgresConfiguration = try PostgresClient.Configuration(config: postgresConfig, role: "owner")
        let database = try postgresConfig.requiredString(forKey: "db")
        let serviceRole = try postgresConfig.requiredString(forKey: "service.user")
        let internalRole = try postgresConfig.requiredString(forKey: "internal.user")

        // MARK: - Composition
        try await PostgresClient.withClient(configuration: ownerPostgresConfiguration, logger: logger) { client in
            let migrations = Migrations(
                client: client,
                database: database,
                serviceRole: serviceRole,
                internalRole: internalRole,
                logger: logger
            )
            try await migrations.apply()
        }
    }
}
