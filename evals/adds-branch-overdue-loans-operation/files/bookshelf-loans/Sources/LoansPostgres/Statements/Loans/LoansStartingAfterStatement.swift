import LoansCore
import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One page of every member's loans by key, newest first, and one loan more to tell whether another page follows.
struct LoansStartingAfterStatement: PostgresPreparedStatement {
    static let sql = """
        SELECT id, user_id, book_id, status, due_date, creation_date
        FROM loans
        WHERE id < COALESCE($1, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
        ORDER BY id DESC
        LIMIT $2 + 1
        """

    let startingAfter: UUID?
    let pageSize: Int

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings()
        bindings.append(startingAfter)
        bindings.append(pageSize)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Loan {
        try Loan(row: row)
    }
}
