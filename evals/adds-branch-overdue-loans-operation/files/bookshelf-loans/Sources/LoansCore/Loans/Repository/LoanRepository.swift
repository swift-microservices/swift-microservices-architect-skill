#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

/// The persistence of loans.
package protocol LoanRepository: Sendable {
    /// Creates a loan, or returns the one an earlier request with the same idempotency key created.
    func create(_ command: CreateLoanCommand) async throws -> Loan

    /// One page of a member's loans by page number, newest first.
    func loans(userID: UUID, page: Int, pageSize: Int) async throws -> Page<Loan>

    /// One page of every member's loans by key, newest first, after the loan `startingAfter` names.
    func loans(startingAfter: UUID?, pageSize: Int) async throws -> KeyedPage<Loan>
}
