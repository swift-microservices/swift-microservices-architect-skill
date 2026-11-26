package import LoansCore
package import Logging
package import PersistencePostgres
package import PostgresNIO

/// A unit of work as `loans_service`, whose policies narrow `loans` to the bound caller's rows.
package struct PostgresLoansScope: PostgresScope, ListLoansUseCaseScope {
    package let loanRepository: any LoanRepository

    package init(connection: PostgresConnection, logger: Logger) {
        self.loanRepository = PostgresLoanRepository(connection: connection, logger: logger)
    }
}
