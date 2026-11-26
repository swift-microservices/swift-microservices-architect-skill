import LoansPostgres
import Logging
import PostgresMigrations
import PostgresNIO

/// Applies Loans' pending migrations as the database's owner, in the order `LoansMigrations` states.
struct Migrations {
    private let client: PostgresClient
    private let database: String
    private let serviceRole: String
    private let internalRole: String
    private let logger: Logger

    init(client: PostgresClient, database: String, serviceRole: String, internalRole: String, logger: Logger) {
        self.client = client
        self.database = database
        self.serviceRole = serviceRole
        self.internalRole = internalRole
        self.logger = logger
    }

    func apply() async throws {
        let migrations = DatabaseMigrations()
        let loansMigrations = LoansMigrations.all(
            database: database,
            serviceRole: serviceRole,
            internalRole: internalRole
        )
        await migrations.add(contentsOf: loansMigrations)

        // A rolled-back image starts on a schema that holds migrations its list lacks.
        try await migrations.apply(
            client: client,
            logger: logger,
            dryRun: false,
            options: .ignoreUnknownMigrations
        )
    }
}
