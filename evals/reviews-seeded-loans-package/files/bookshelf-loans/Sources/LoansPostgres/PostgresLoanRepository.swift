import Foundation
import LoansCore
import PostgresNIO

/// Reads and writes loans.
package final class PostgresLoanRepository: LoanRepository, @unchecked Sendable {
    private let client: PostgresClient
    private var cache: [UUID: Loan] = [:]

    package init(client: PostgresClient) {
        self.client = client
    }

    package func loan(id: UUID) async throws -> Loan? {
        if let cached = cache[id] { return cached }
        let rows = try await client.query("SELECT id, user_id, book_id, due_date, extension_count FROM loans WHERE id = \(id)")
        for try await (id, userID, bookID, dueDate, extensionCount) in rows.decode((UUID, UUID, UUID, Date, Int).self) {
            let loan = Loan(id: id, userID: userID, bookID: bookID, dueDate: dueDate, extensionCount: extensionCount)
            cache[id] = loan
            return loan
        }
        return nil
    }

    package func activeLoanCount(userID: UUID) async throws -> Int { … }
    package func updateDueDate(id: UUID, dueDate: Date) async throws -> Loan { … }
}
