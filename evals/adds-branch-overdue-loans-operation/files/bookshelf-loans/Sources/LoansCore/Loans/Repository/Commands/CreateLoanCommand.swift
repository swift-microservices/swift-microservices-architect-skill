#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

/// A loan a member takes out at a branch.
package struct CreateLoanCommand: Sendable {
    package let userID: UUID
    package let bookID: UUID
    package let branchID: UUID
    package let dueDate: Date
    package let idempotencyKey: String

    package init(userID: UUID, bookID: UUID, branchID: UUID, dueDate: Date, idempotencyKey: String) {
        self.userID = userID
        self.bookID = bookID
        self.branchID = branchID
        self.dueDate = dueDate
        self.idempotencyKey = idempotencyKey
    }
}
