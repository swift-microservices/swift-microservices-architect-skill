import LoansCore
import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension Loan {
    /// A loan from the columns every loan statement returns, in their order.
    init(row: PostgresRow) throws {
        let (id, userID, bookID, status, dueDate, creationDate) = try row.decode(
            (UUID, UUID, UUID, LoanStatus, Date, Date).self
        )
        self.init(id: id, userID: userID, bookID: bookID, status: status, dueDate: dueDate, creationDate: creationDate)
    }
}
