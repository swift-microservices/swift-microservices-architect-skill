import AsyncAlgorithms
import LoansCore
import Logging
import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct PostgresLoanRepository: LoanRepository {
    let connection: PostgresConnection
    let logger: Logger

    func create(_ command: CreateLoanCommand) async throws -> Loan {
        let statement = CreateLoanStatement(command: command)

        do {
            let rows = try await connection.execute(statement, logger: logger)
            let loans = try await Array(rows)
            // The key's first request made a loan of another book, so the insert returns no row.
            guard let loan = loans.first else {
                throw LoanRepositoryError.idempotencyConflict
            }

            return loan
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            switch error.serverInfo?[.constraintName] {
            case "loans_active_user_id_book_id_key":
                throw LoanRepositoryError.alreadyBorrowed
            default:
                throw error
            }
        }
    }

    func loans(userID: UUID, page: Int, pageSize: Int) async throws -> Page<Loan> {
        let statement = LoansByUserIDStatement(userID: userID, page: page, pageSize: pageSize)
        let rows = try await connection.execute(statement, logger: logger)
        let loans = try await Array(rows)

        let countStatement = CountLoansByUserIDStatement(userID: userID)
        let countRows = try await connection.execute(countStatement, logger: logger)
        let counts = try await Array(countRows)
        let totalCount = counts.first ?? 0

        return Page(items: loans, page: page, pageSize: pageSize, totalCount: totalCount)
    }

    func loans(startingAfter: UUID?, pageSize: Int) async throws -> KeyedPage<Loan> {
        let statement = LoansStartingAfterStatement(startingAfter: startingAfter, pageSize: pageSize)
        let rows = try await connection.execute(statement, logger: logger)
        let loans = try await Array(rows)

        // The statement reads one loan past the page, which comes back only when another page follows.
        guard loans.count > pageSize else {
            return KeyedPage(items: loans, nextCursor: nil)
        }

        let items = Array(loans.prefix(pageSize))
        let nextCursor = items.last?.id
        return KeyedPage(items: items, nextCursor: nextCursor)
    }
}
