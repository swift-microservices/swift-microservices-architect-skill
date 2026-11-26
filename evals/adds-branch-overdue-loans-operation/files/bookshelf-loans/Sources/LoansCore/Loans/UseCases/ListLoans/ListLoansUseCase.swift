package import BookshelfAuthentication
package import Logging
package import Persistence

/// Lists the subject's own loans, a page at a time, newest first.
///
/// The member is the token's subject; the request names only the page. Runs on the tenant
/// database, where the policy confines the transaction to the member's own loans.
package struct ListLoansUseCase<DatabaseType>: ListLoansUseCaseProtocol
where DatabaseType: Database, DatabaseType.Scope: ListLoansUseCaseScope {
    private let database: DatabaseType
    private let logger: Logger

    package init(database: DatabaseType, logger: Logger) {
        self.database = database
        self.logger = logger
    }

    package func callAsFunction(
        subject: UserIdentity,
        input: ListLoansUseCaseInput
    ) async throws(ListLoansUseCaseError) -> Page<Loan> {
        do {
            return try await database.withTransaction { scope in
                try await scope.loanRepository.loans(
                    userID: subject.userID,
                    page: input.page,
                    pageSize: input.pageSize
                )
            }
        } catch is CancellationError {
            throw .unknown
        } catch {
            logger.error("Member loan list failed: unknown error", metadata: ["error": "\(error)"])
            throw .unknown
        }
    }
}
