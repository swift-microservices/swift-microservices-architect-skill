package import BookshelfAuthentication
package import Logging
package import Persistence

/// Lists every member's loans for an administrator, a page at a time by key, newest first.
///
/// The gateway's administrator context refuses other callers earlier; the role check here is
/// the rule. Runs on the internal database, whose role sees every member's loans.
package struct ListAllLoansUseCase<DatabaseType>: ListAllLoansUseCaseProtocol
where DatabaseType: Database, DatabaseType.Scope: ListAllLoansUseCaseScope {
    private let database: DatabaseType
    private let logger: Logger

    package init(database: DatabaseType, logger: Logger) {
        self.database = database
        self.logger = logger
    }

    package func callAsFunction(
        subject: UserIdentity,
        input: ListAllLoansUseCaseInput
    ) async throws(ListAllLoansUseCaseError) -> KeyedPage<Loan> {
        guard subject.role == .admin else {
            logger.warning("Loan list refused: not an administrator")
            throw .forbidden
        }

        do {
            return try await database.withTransaction { scope in
                try await scope.loanRepository.loans(startingAfter: input.startingAfter, pageSize: input.pageSize)
            }
        } catch is CancellationError {
            throw .unknown
        } catch {
            logger.error("Loan list failed: unknown error", metadata: ["error": "\(error)"])
            throw .unknown
        }
    }
}
