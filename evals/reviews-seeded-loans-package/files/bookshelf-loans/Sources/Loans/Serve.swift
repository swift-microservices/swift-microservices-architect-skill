import ArgumentParser
import Configuration
import LoansCore
import LoansGRPC
import LoansPostgres
import Logging
import PostgresNIO
import ServiceLifecycle

/// Runs Loans' gRPC server.
struct Serve: AsyncParsableCommand {
    func run() async throws {
        let config = ConfigReader(provider: EnvironmentVariablesProvider())
        let logger = Logger(label: "loans")

        // MARK: - Postgres

        let postgresConfiguration = PostgresClient.Configuration(
            host: config.string(forKey: "postgres.host", default: "localhost"),
            username: "bookshelf_loans",  // the database's owner
            password: config.string(forKey: "postgres.password", default: "loans"),
            database: "bookshelf_loans",
            tls: .disable
        )
        let postgresClient = PostgresClient(configuration: postgresConfiguration)
        let loanRepository = PostgresLoanRepository(client: postgresClient)

        // MARK: - Use cases

        let extendLoan = ExtendLoanUseCase(loanRepository: loanRepository, noticeSender: LoggingNoticeSender(), policy: .standard, logger: logger)

        // MARK: - gRPC

        let loanService = try await LoanService(extendLoan: extendLoan)
        let server = GRPCServer(transport: .http2NIOPosix(address: .ipv4(host: "0.0.0.0", port: 8080), transportSecurity: .plaintext), services: [loanService])

        let serviceGroup = ServiceGroup(services: [server], logger: logger)
        try await serviceGroup.run()
    }
}
