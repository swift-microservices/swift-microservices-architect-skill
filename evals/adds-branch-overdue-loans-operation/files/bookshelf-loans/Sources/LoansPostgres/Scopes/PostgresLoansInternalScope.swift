package import LoansCore
package import Logging
package import PersistencePostgres
package import PostgresNIO

/// A unit of work as `loans_internal`, whose policy lets it see every loan, so its use cases confine the work.
package struct PostgresLoansInternalScope: PostgresScope, ListAllLoansUseCaseScope {
    package let loanRepository: any LoanRepository

    package init(connection: PostgresConnection, logger: Logger) {
        self.loanRepository = PostgresLoanRepository(connection: connection, logger: logger)
    }
}
