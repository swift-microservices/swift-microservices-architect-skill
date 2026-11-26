import ArgumentParser
import BookshelfPersistence
import Configuration
import LoansPostgres
import Logging
import PersistencePostgres
import PostgresNIO

struct BuildIndexes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-indexes",
        abstract: "Build the indexes LoansIndexes lists without blocking writes, then exit"
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

        // MARK: - Composition
        try await PostgresClient.withClient(configuration: ownerPostgresConfiguration, logger: logger) { client in
            for index in LoansIndexes.all {
                let validityQuery: PostgresQuery = """
                    SELECT pg_index.indisvalid
                    FROM pg_index JOIN pg_class ON pg_class.oid = pg_index.indexrelid
                    WHERE pg_class.relname = \(index.name)
                    """
                let validityRows = try await client.query(validityQuery, logger: logger)

                // An interrupted build leaves an invalid index behind, which IF NOT EXISTS would keep.
                for try await isValid in validityRows.decode(Bool.self) where !isValid {
                    let dropSQL = "DROP INDEX CONCURRENTLY IF EXISTS \(index.name)"
                    let dropQuery = PostgresQuery(unsafeSQL: dropSQL)
                    try await client.query(dropQuery, logger: logger)
                }

                let createSQL = "CREATE INDEX CONCURRENTLY IF NOT EXISTS \(index.name) \(index.definition)"
                let createQuery = PostgresQuery(unsafeSQL: createSQL)
                try await client.query(createQuery, logger: logger)
                logger.info("Index built", metadata: ["index": "\(index.name)"])
            }
        }
    }
}
