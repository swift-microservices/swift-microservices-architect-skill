import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// How many loans a member has, for the page count of their list.
struct CountLoansByUserIDStatement: PostgresPreparedStatement {
    static let sql = "SELECT count(*) FROM loans WHERE user_id = $1"

    let userID: UUID

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings()
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Int {
        try row.decode(Int.self)
    }
}
