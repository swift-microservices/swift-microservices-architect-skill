import LoansCore
import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One page of a member's loans by page number, newest first.
struct LoansByUserIDStatement: PostgresPreparedStatement {
    static let sql = """
        SELECT id, user_id, book_id, status, due_date, creation_date
        FROM loans
        WHERE user_id = $1
        ORDER BY id DESC
        LIMIT $2 OFFSET ($3 - 1) * $2
        """

    let userID: UUID
    let page: Int
    let pageSize: Int

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings()
        bindings.append(userID)
        bindings.append(pageSize)
        bindings.append(page)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Loan {
        try Loan(row: row)
    }
}
