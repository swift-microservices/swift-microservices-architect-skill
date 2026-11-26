#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

/// A member's loan of one copy of a book, from its borrowing until its return.
package struct Loan: Equatable, Sendable {
    package let id: UUID
    package let userID: UUID
    package let bookID: UUID
    package let status: LoanStatus
    package let dueDate: Date
    package let creationDate: Date

    package init(id: UUID, userID: UUID, bookID: UUID, status: LoanStatus, dueDate: Date, creationDate: Date) {
        self.id = id
        self.userID = userID
        self.bookID = bookID
        self.status = status
        self.dueDate = dueDate
        self.creationDate = creationDate
    }
}
